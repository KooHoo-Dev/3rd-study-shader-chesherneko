// [믹스 1] 툰 바다 = 램프 툰 조명 + 물결 수면 + 깊이 기반 물가 거품 (URP 17, HLSL)
//
// 원본 (Shader Gallery, https://koohoo-dev.github.io/edu-lecture-shader-gallery/)
//   - 물결 수면 (water-wave-surface)     : 사인파 세 개로 정점을 출렁이고, 도함수로 픽셀마다 법선을 다시 구한다.
//   - 깊이 기반 물가 거품 (water-depth-foam): 씬 깊이와 비교해 물체 둘레에 거품 띠를 그리고 얕은 곳을 투명하게 한다.
//   - 램프 툰 조명 (toon-ramp-lit)        : dot(N, L) 을 몇 개의 띠로 끊고 그늘 색으로 색조를 바꾼다.
//
// 섞은 지점
//   1. 파도 법선 + 잔물결 법선을 합친 법선으로 dot(N, L) 을 구하고, 그것을 툰 띠로 끊는다.
//   2. 깊이 색(얕은 색 → 깊은 색)도 같은 띠 함수로 끊어 등고선처럼 단계진 물빛을 만든다.
//   3. 프레넬(하늘빛)과 반사광을 smoothstep 으로 잘라 만화풍의 딱 끊긴 반사 덩어리로 바꾼다.
//   4. 물가 거품에 더해 파도 마루에도 거품을 얹고, 거품도 툰 그늘 색을 받는다.
//
// 필요 설정: URP Asset 의 Depth Texture 켜기. 메시는 촘촘한 평면(정점 간격 0.1 m 권장).
Shader "ShaderGallery/Mix/ToonWater"
{
    Properties
    {
        [Header(Wave from Water Wave Surface)]
        _WaveHeight ("파도 높이", Range(0, 0.3)) = 0.08
        _WaveLength ("파장", Range(0.8, 6)) = 2.6
        _WaveSpeed ("파도 속도", Range(0, 3)) = 0.8
        _WaveAngle ("파도 방향 (Y 회전, 도)", Range(0, 360)) = 225

        [Header(Toon from Toon Ramp Lit)]
        _Bands ("빛 띠 수", Range(2, 5)) = 3
        _Softness ("경계 부드러움", Range(0, 0.5)) = 0.05
        _ShadeShift ("그늘 넓이", Range(-0.25, 0.6)) = 0
        _ShadeColor ("그늘 색", Color) = (0.48, 0.52, 0.9, 1)
        _FresnelCut ("하늘 반사 경계", Range(0.02, 1)) = 0.3
        _SpecPower ("반사광 날카로움", Range(4, 512)) = 160
        _SpecCut ("반사광 경계", Range(0.05, 1)) = 0.5
        _SpecStrength ("반사광 세기", Range(0, 3)) = 1.2

        [Header(Water Color from Depth Foam)]
        _ShallowColor ("얕은 색", Color) = (0.25, 0.85, 0.78, 1)
        _DeepColor ("깊은 색", Color) = (0.05, 0.22, 0.42, 1)
        _SkyColor ("하늘빛", Color) = (0.62, 0.84, 1, 1)
        _DepthRange ("깊이 범위", Range(0.1, 5)) = 1.6
        _DepthBands ("깊이 띠 수", Range(2, 6)) = 4

        [Header(Foam from Depth Foam)]
        [NoScaleOffset] _NoiseTex ("노이즈 텍스처 (sRGB 끔)", 2D) = "linearGrey" {}
        _FoamColor ("거품 색", Color) = (0.96, 0.99, 1, 1)
        _FoamWidth ("물가 거품 폭", Range(0.02, 1)) = 0.4
        _FoamBreakup ("거품 끊김", Range(0, 1)) = 0.8
        _CrestFoam ("마루 거품 경계 (1 이면 없음)", Range(0.5, 1)) = 0.9
        _FlowSpeed ("흐름 속도", Range(0, 2)) = 0.6
        _RippleScale ("잔물결 반복 수", Range(1, 24)) = 8
        _RippleStrength ("잔물결 세기", Range(0, 1)) = 0.35
    }

    SubShader
    {
        Tags { "RenderType" = "Transparent" "Queue" = "Transparent" "RenderPipeline" = "UniversalPipeline" }

        Pass
        {
            Name "Forward"
            Tags { "LightMode" = "UniversalForward" }

            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT

            // 투명 물체는 화면 공간 그림자 텍스처 대신 그림자 맵을 직접 읽는다 (물결 수면 원본과 같다).
            #define _SURFACE_TYPE_TRANSPARENT 1

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"

            TEXTURE2D(_NoiseTex);
            SAMPLER(sampler_NoiseTex);

            CBUFFER_START(UnityPerMaterial)
                float4 _NoiseTex_TexelSize;
                float _WaveHeight;
                float _WaveLength;
                float _WaveSpeed;
                float _WaveAngle;
                float _Bands;
                float _Softness;
                float _ShadeShift;
                float4 _ShadeColor;
                float _FresnelCut;
                float _SpecPower;
                float _SpecCut;
                float _SpecStrength;
                float4 _ShallowColor;
                float4 _DeepColor;
                float4 _SkyColor;
                float _DepthRange;
                float _DepthBands;
                float4 _FoamColor;
                float _FoamWidth;
                float _FoamBreakup;
                float _CrestFoam;
                float _FlowSpeed;
                float _RippleScale;
                float _RippleStrength;
            CBUFFER_END

            #define SG_TEX(name, uv) SAMPLE_TEXTURE2D(name, sampler##name, uv)
            #define WAVE_TAU 6.2831853

            // ---------------------------------------------------------------
            // [물결 수면] 원본 그대로: 파도 하나 = (높이, dh/dx, dh/dz)
            // ---------------------------------------------------------------
            float3 waveOne(float2 xz, float angleDeg, float lambda, float amp, float speed, float time)
            {
                float a = angleDeg * 0.0174533;
                float2 dir = float2(sin(a), cos(a));
                float k = WAVE_TAU / lambda;
                float phase = k * dot(dir, xz) - WAVE_TAU * frac(time * speed / lambda);
                float s = sin(phase);
                float c = amp * k * cos(phase);
                return float3(amp * s, c * dir.x, c * dir.y);
            }

            float3 waveSum(float2 xz, float time)
            {
                float3 w = waveOne(xz, _WaveAngle, _WaveLength, _WaveHeight, _WaveSpeed, time);
                w += waveOne(xz, _WaveAngle + 55.0, _WaveLength * 0.77, _WaveHeight * 0.6, _WaveSpeed * 0.88, time);
                w += waveOne(xz, _WaveAngle - 40.0, _WaveLength * 0.58, _WaveHeight * 0.4, _WaveSpeed * 0.76, time);
                return w;
            }

            // ---------------------------------------------------------------
            // [램프 툰 조명] 원본의 toonBands 를 띠 수와 부드러움을 인자로 받게 바꿨다.
            // 같은 함수로 빛 띠와 깊이 띠를 모두 끊는다.
            // ---------------------------------------------------------------
            float toonMax3(float3 c) { return max(c.r, max(c.g, c.b)); }

            float toonSteps(float level, float bandCount, float softness)
            {
                float bands = max(floor(bandCount + 0.5), 2.0);
                float t = level * bands - 0.5;
                float cell = floor(t);
                float f = t - cell;
                float w = clamp(max(softness, fwidth(t)), 0.001, 0.5);
                float stepped = cell + smoothstep(0.5 - w, 0.5 + w, f);
                return saturate(stepped / (bands - 1.0));
            }

            // 0~1 값을 경계 하나에서 딱 끊는다. 툰 프레넬, 툰 반사광에 쓴다. fwidth 로 1~2 픽셀은 이어 계단을 막는다.
            float toonCut(float value, float edge, float softness)
            {
                float w = max(softness, fwidth(value));
                return smoothstep(edge - w, edge + w, value);
            }

            // ---------------------------------------------------------------
            // [깊이 기반 물가 거품] 원본 그대로: 잔물결 높이
            // ---------------------------------------------------------------
            float2 waterFoamRotate(float2 p, float radians)
            {
                float s = sin(radians);
                float c = cos(radians);
                return float2(p.x * c - p.y * s, p.x * s + p.y * c);
            }

            float waterFoamRipple(float2 uv, float2 flowA, float2 flowB)
            {
                float a = SG_TEX(_NoiseTex, uv * _RippleScale - flowA).r;
                float b = SG_TEX(_NoiseTex, waterFoamRotate(uv * (_RippleScale * 1.6), 0.6) + float2(0.37, 0.61) - flowB).r;
                return (a + b) * 0.5;
            }

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float2 uv : TEXCOORD0;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 positionOS : TEXCOORD1;
                float3 positionWS : TEXCOORD2;
                float3 normalWS : TEXCOORD3;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            Varyings vert(Attributes v)
            {
                Varyings o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_TRANSFER_INSTANCE_ID(v, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                // [물결 수면] 높이만 민다. xz 는 그대로라 픽셀 단계에서 같은 식으로 기울기를 다시 구할 수 있다.
                float3 p = v.positionOS.xyz;
                p.y += waveSum(p.xz, _Time.y).x;
                o.positionWS = TransformObjectToWorld(p);
                o.positionCS = TransformWorldToHClip(o.positionWS);
                o.normalWS = TransformObjectToWorldNormal(v.normalOS);
                o.positionOS = p;
                o.uv = v.uv;
                return o;
            }

            float4 frag(Varyings v) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(v);
                float time = _Time.y;
                float3 viewWS = GetWorldSpaceNormalizeViewDir(v.positionWS);

                // 1. [물결 수면] 큰 파도 법선 (오브젝트 공간 → 월드)
                float3 w = waveSum(v.positionOS.xz, time);
                float3 n = normalize(TransformObjectToWorldNormal(normalize(float3(-w.y, 1.0, -w.z))));

                // 2. [물가 거품] 잔물결 법선을 큰 파도 법선 위에 더한다.
                float tf = time * _FlowSpeed;
                float2 flowA = frac(float2(0.15, 0.05) * tf);
                float2 flowB = frac(float2(-0.07, -0.12) * tf);
                float e = _NoiseTex_TexelSize.x / _RippleScale;
                float rh = waterFoamRipple(v.uv, flowA, flowB);
                float rhu = waterFoamRipple(v.uv + float2(e, 0.0), flowA, flowB);
                float rhv = waterFoamRipple(v.uv + float2(0.0, e), flowA, flowB);
                float2 slope = float2(rhu - rh, rhv - rh) * 10.0 * _RippleStrength;
                n = normalize(n + float3(slope.x, 0.0, slope.y));

                // 3. [램프 툰] 주 광원과 받는 그림자. 그림자 감쇠를 띠로 끊기 전에 곱해 그림자도 같은 단계로 보인다.
                Light light = GetMainLight(TransformWorldToShadowCoord(v.positionWS), v.positionWS, half4(1, 1, 1, 1));
                float3 lightColor = light.color * light.shadowAttenuation;
                float lightAmount = toonMax3(lightColor);
                float shadow = saturate(lightAmount);
                float3 lightHue = lerp(float3(1, 1, 1), lightColor / max(lightAmount, 0.0001), step(0.0001, lightAmount));
                float ndl = dot(n, light.direction);
                float level = saturate((ndl - _ShadeShift) / (1.0 - _ShadeShift)) * shadow;
                float band = toonSteps(level, _Bands, _Softness);
                float3 tint = lerp(_ShadeColor.rgb, lightHue, band);

                // 4. [물가 거품] 깊이 차이 → [램프 툰] 띠로 끊어 등고선 같은 단계진 물빛
                float2 screenUV = GetNormalizedScreenSpaceUV(v.positionCS);
                float sceneEye = LinearEyeDepth(SampleSceneDepth(screenUV), _ZBufferParams);
                float selfEye = LinearEyeDepth(v.positionWS, UNITY_MATRIX_V);
                float depthDelta = sceneEye - selfEye;
                float depth01 = saturate(depthDelta / _DepthRange);
                float deepT = 1.0 - (1.0 - depth01) * (1.0 - depth01);
                float deepStep = toonSteps(deepT, _DepthBands, _Softness * 0.5);
                float3 water = lerp(_ShallowColor.rgb, _DeepColor.rgb, deepStep);
                float alpha = lerp(0.25, 0.95, deepStep);
                float3 color = water * tint;

                // 5. [물결 수면] 프레넬 → [램프 툰] 딱 끊긴 하늘 반사 덩어리
                float fresnel = 0.02 + 0.98 * pow(1.0 - saturate(dot(n, viewWS)), 5.0);
                float fresnelToon = toonCut(fresnel, _FresnelCut, _Softness * 0.3);
                color = lerp(color, _SkyColor.rgb, fresnelToon * 0.85);

                // 6. [물결 수면] 블린-퐁 반사광 → [램프 툰] 점이 아니라 평평한 흰 조각으로 끊는다. 그림자 안에서는 없다.
                float3 halfDir = normalize(light.direction + viewWS);
                float spec = pow(saturate(dot(n, halfDir)), _SpecPower);
                float specToon = toonCut(spec, _SpecCut, 0.02) * shadow * _SpecStrength;
                color += lightHue * specToon;

                // 7. [물가 거품] 물체와 닿는 곳의 거품 띠 (원본 그대로)
                float foamNoise = SG_TEX(_NoiseTex, v.uv * (_RippleScale * 1.7) + float2(0.71, 0.13) - frac(float2(0.11, 0.04) * tf)).r;
                float surge = 0.85 + 0.15 * sin(time * 1.7 + rh * 6.2832);
                float edge = saturate(depthDelta / (_FoamWidth * surge));
                float pattern = lerp(0.6, foamNoise, _FoamBreakup);
                float foam = smoothstep(edge - 0.04, edge + 0.04, pattern);
                foam = max(foam, 1.0 - smoothstep(0.0, 0.12, edge));

                // 8. [믹스] 파도 마루 거품: 파도 높이(0~1)가 경계를 넘는 곳. 노이즈로 경계를 흔들어 덩어리로 끊는다.
                float h01 = saturate(0.5 + 0.5 * w.x / max(_WaveHeight * 2.0, 0.0001));
                float crest = toonCut(h01 + (foamNoise - 0.5) * 0.35, _CrestFoam, 0.02) * step(0.0001, _WaveHeight);
                foam = max(foam, crest);

                // 거품도 툰 그늘 색을 받는다. 그늘진 거품은 그늘 색조가 된다.
                float3 foamColor = _FoamColor.rgb * tint;
                color = lerp(color, foamColor, foam);
                alpha = saturate(alpha + fresnelToon * 0.8 + specToon);
                alpha = lerp(alpha, 1.0, foam);
                return float4(color, alpha);
            }
            ENDHLSL
        }
    }
}

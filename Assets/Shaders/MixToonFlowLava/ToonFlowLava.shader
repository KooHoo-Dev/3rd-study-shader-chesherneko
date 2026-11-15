// [믹스 6] 툰 용암 = 플로 맵 액체 + 램프 툰 조명 + 프레넬 림 빛 (URP 17, HLSL)
//
// 원본 (Shader Gallery)
//   - 플로 맵 액체 (flow-map-liquid) : 방향 텍스처로 UV 를 흘리고, 반 주기 어긋난 두 위상을 삼각파로 섞는다.
//   - 램프 툰 조명 (toon-ramp-lit)   : dot(N, L) 을 띠로 끊고 lerp(그늘 색, 빛 색, 띠) 를 기본 색에 곱한다.
//   - 프레넬 림 빛 (fresnel-rim-glow): 1 - dot(N, V) 를 거듭제곱해 윤곽을 밝힌다.
//
// 섞은 지점
//   1. 흐르는 무늬 밝기(pat)도 툰 띠 함수로 끊어, 매끈한 용암 대신 칸이 나뉜 만화풍 용암을 만든다 (_PatternBands, 0 이면 끔).
//   2. 무늬로 고른 알베도에 [램프 툰]의 그늘 색조를 곱한다. 발광은 툰 조명과 무관하게 더해 그늘에서도 빛난다.
//   3. [프레넬 림]을 smoothstep 으로 잘라 굵고 평평한 툰 림으로 바꾼다. 림 색은 용암 밝기를 따라 뜨거운 곳일수록 밝다.
Shader "ShaderGallery/Mix/ToonFlowLava"
{
    Properties
    {
        [Header(Flow Map Liquid)]
        [NoScaleOffset] _FlowTex ("플로 맵 (RG 흐름, B 위상 노이즈, sRGB 끔)", 2D) = "linearGrey" {}
        [NoScaleOffset] _PatternTex ("무늬 텍스처 (sRGB 끔)", 2D) = "linearGrey" {}
        _FlowStrength ("흐름 세기", Range(0, 0.5)) = 0.15
        _Speed ("흐름 속도", Range(0, 2)) = 0.25
        _PhaseNoise ("위상 노이즈", Range(0, 1)) = 1
        _PatternScale ("무늬 반복 수", Range(0.5, 12)) = 3
        _DeepColor ("식은 색", Color) = (0.22, 0.04, 0.05, 1)
        _BrightColor ("뜨거운 색", Color) = (1, 0.47, 0.08, 1)
        _Glow ("발광 (HDR)", Range(0, 8)) = 1.6

        [Header(Toon Ramp Lit)]
        _Bands ("빛 띠 수", Range(2, 5)) = 3
        _Softness ("경계 부드러움", Range(0, 0.5)) = 0.05
        _ShadeShift ("그늘 넓이", Range(-0.25, 0.6)) = 0
        _ShadeColor ("그늘 색", Color) = (0.42, 0.26, 0.55, 1)
        _PatternBands ("무늬 띠 수 (0 이면 매끈)", Range(0, 6)) = 3

        [Header(Fresnel Rim Glow)]
        _RimColor ("림 색", Color) = (1, 0.72, 0.3, 1)
        _RimPower ("림 지수", Range(0.5, 8)) = 3
        _RimIntensity ("림 세기", Range(0, 4)) = 1.5
        _RimCut ("툰 림 경계", Range(0.01, 1)) = 0.35
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" "Queue" = "Geometry" "RenderPipeline" = "UniversalPipeline" }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

        TEXTURE2D(_FlowTex);
        SAMPLER(sampler_FlowTex);
        TEXTURE2D(_PatternTex);
        SAMPLER(sampler_PatternTex);

        CBUFFER_START(UnityPerMaterial)
            float _FlowStrength;
            float _Speed;
            float _PhaseNoise;
            float _PatternScale;
            float4 _DeepColor;
            float4 _BrightColor;
            float _Glow;
            float _Bands;
            float _Softness;
            float _ShadeShift;
            float4 _ShadeColor;
            float _PatternBands;
            float4 _RimColor;
            float _RimPower;
            float _RimIntensity;
            float _RimCut;
        CBUFFER_END

        #define SG_TEX(name, uv) SAMPLE_TEXTURE2D(name, sampler##name, uv)

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
            float3 positionWS : TEXCOORD1;
            float3 normalWS : TEXCOORD2;
            UNITY_VERTEX_INPUT_INSTANCE_ID
            UNITY_VERTEX_OUTPUT_STEREO
        };

        Varyings vert(Attributes v)
        {
            Varyings o;
            UNITY_SETUP_INSTANCE_ID(v);
            UNITY_TRANSFER_INSTANCE_ID(v, o);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
            o.positionWS = TransformObjectToWorld(v.positionOS.xyz);
            o.positionCS = TransformWorldToHClip(o.positionWS);
            o.normalWS = TransformObjectToWorldNormal(v.normalOS);
            o.uv = v.uv;
            return o;
        }
        ENDHLSL

        Pass
        {
            Name "Forward"
            Tags { "LightMode" = "UniversalForwardOnly" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT

            // ---------------------------------------------------------------
            // [플로 맵 액체] 원본 그대로
            // ---------------------------------------------------------------
            float flowPattern(float2 uv, float2 flow, float phase)
            {
                float2 p = (uv - flow * phase) * _PatternScale;
                return SG_TEX(_PatternTex, p).r;
            }

            float flowWeight(float phase)
            {
                return 1.0 - abs(1.0 - 2.0 * phase);
            }

            // ---------------------------------------------------------------
            // [램프 툰 조명] 원본의 toonBands 를 띠 수와 부드러움을 인자로 받게 바꿨다.
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

            float4 frag(Varyings v) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(v);
                float3 n = normalize(v.normalWS);
                float3 viewWS = GetWorldSpaceNormalizeViewDir(v.positionWS);

                // 1. [플로 맵] 두 위상을 삼각파로 섞은 흐르는 무늬 (원본 그대로)
                float3 flowTexel = SG_TEX(_FlowTex, v.uv).rgb;
                float2 flow = (flowTexel.xy * 2.0 - 1.0) * _FlowStrength;
                float t = _Time.y * _Speed;
                float pn = flowTexel.z * _PhaseNoise;
                float phaseA = frac(t + pn);
                float phaseB = frac(t + pn + 0.5);
                float patA = flowPattern(v.uv, flow, phaseA);
                float patB = flowPattern(v.uv, flow, phaseB);
                float wA = flowWeight(phaseA);
                float pat = patA * wA + patB * (1.0 - wA);

                // 2. [믹스] 무늬 밝기도 툰 띠로 끊는다. 띠 수 0~1 이면 원본처럼 매끈하게 둔다.
                float patToon = _PatternBands >= 1.5 ? toonSteps(pat, _PatternBands, _Softness) : pat;
                float3 albedo = lerp(_DeepColor.rgb, _BrightColor.rgb, patToon);

                // 3. [램프 툰] 주 광원을 띠로 끊고 그늘 색조를 곱한다. 그림자 감쇠는 끊기 전에 곱한다.
                Light light = GetMainLight(TransformWorldToShadowCoord(v.positionWS), v.positionWS, half4(1, 1, 1, 1));
                float3 lightColor = light.color * light.shadowAttenuation;
                float lightAmount = toonMax3(lightColor);
                float3 lightHue = lerp(float3(1, 1, 1), lightColor / max(lightAmount, 0.0001), step(0.0001, lightAmount));
                float ndl = dot(n, light.direction);
                float level = saturate((ndl - _ShadeShift) / (1.0 - _ShadeShift)) * saturate(lightAmount);
                float band = toonSteps(level, _Bands, _Softness);
                float3 color = albedo * lerp(_ShadeColor.rgb, lightHue, band);

                // 4. [플로 맵] 발광: 뜨거운 곳은 스스로 빛난다. 툰 조명 뒤에 더해 그늘에서도 꺼지지 않는다.
                color += _BrightColor.rgb * (patToon * patToon) * _Glow;

                // 5. [프레넬 림] 1 - N·V 를 거듭제곱 → [툰] 경계 하나로 딱 끊는다. 뜨거운 무늬 위에서 더 밝다.
                float rim = pow(max(1.0 - saturate(dot(n, viewWS)), 0.0001), _RimPower);
                float rimW = max(_Softness * 0.5, fwidth(rim));
                float rimToon = smoothstep(_RimCut - rimW, _RimCut + rimW, rim);
                color += _RimColor.rgb * _RimIntensity * rimToon * lerp(0.5, 1.5, patToon);

                return float4(color, 1.0);
            }
            ENDHLSL
        }

        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }
            ZWrite On
            ColorMask 0

            HLSLPROGRAM
            #pragma vertex vertShadow
            #pragma fragment fragShadow
            #pragma multi_compile_instancing
            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW

            float3 _LightDirection;
            float3 _LightPosition;

            Varyings vertShadow(Attributes v)
            {
                Varyings o = vert(v);
                #if _CASTING_PUNCTUAL_LIGHT_SHADOW
                    float3 lightDir = normalize(_LightPosition - o.positionWS);
                #else
                    float3 lightDir = _LightDirection;
                #endif
                o.positionCS = ApplyShadowClamping(TransformWorldToHClip(ApplyShadowBias(o.positionWS, o.normalWS, lightDir)));
                return o;
            }

            float4 fragShadow(Varyings v) : SV_Target
            {
                return 0;
            }
            ENDHLSL
        }

        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }
            ZWrite On
            ColorMask R

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment fragDepth
            #pragma multi_compile_instancing

            float4 fragDepth(Varyings v) : SV_Target
            {
                return v.positionCS.z;
            }
            ENDHLSL
        }

        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormalsOnly" }
            ZWrite On

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment fragNormals
            #pragma multi_compile_instancing
            #pragma multi_compile_fragment _ _GBUFFER_NORMALS_OCT
            #include_with_pragmas "Packages/com.unity.render-pipelines.universal/ShaderLibrary/RenderingLayers.hlsl"

            void fragNormals(Varyings v, out float4 outNormalWS : SV_Target0
            #ifdef _WRITE_RENDERING_LAYERS
                , out uint outRenderingLayers : SV_Target1
            #endif
            )
            {
                float3 normalWS = normalize(v.normalWS);
                #if defined(_GBUFFER_NORMALS_OCT)
                    float2 octNormalWS = PackNormalOctQuadEncode(normalWS);
                    outNormalWS = float4(PackFloat2To888(saturate(octNormalWS * 0.5 + 0.5)), 0.0);
                #else
                    outNormalWS = float4(normalWS, 0.0);
                #endif
                #ifdef _WRITE_RENDERING_LAYERS
                    outRenderingLayers = EncodeMeshRenderingLayer();
                #endif
            }
            ENDHLSL
        }
    }
}

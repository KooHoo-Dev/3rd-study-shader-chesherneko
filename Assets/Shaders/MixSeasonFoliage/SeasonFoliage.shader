// [믹스 5] 계절이 바뀌는 숲 = 삼평면 투영 + 젖음과 눈 쌓임 + 바람 흔들림 (URP 17, HLSL)
//
// 원본 (Shader Gallery)
//   - 삼평면 투영 (triplanar-projection) : UV 없이 세 축에서 텍스처를 투영해 섞는다.
//   - 젖음과 눈 쌓임 (surface-wet-snow)  : 월드 법선 y 와 노이즈로 윗면만 골라 젖은 재질이나 눈을 얹는다.
//   - 바람 흔들림 (wind-sway-foliage)    : 높이(uv.y) 마스크와 흘러가는 돌풍 노이즈로 정점을 민다.
//
// 섞은 지점
//   1. 젖음/눈 원본의 '마른 돌' 텍스처를 UV 대신 [삼평면 투영]으로 읽는다. UV 가 없거나 늘어난 바위, 지형에도 그대로 쓴다.
//   2. [바람] 원본의 뿌리→끝 잎 색 그라데이션을 삼평면 색 위에 곱한다. 바위는 둘 다 흰색으로 두면 영향이 없다.
//   3. [믹스] 눈이 쌓일수록 풀이 무거워져 덜 흔들린다 (_SnowDamping). 젖음 모드에서는 그대로 흔들린다.
//   4. [믹스] 풀잎 끝은 법선이 옆을 봐도 눈을 받는다 (_TipCatch). 세운 잎은 법선 y 가 0 근처라 원본 그대로면 눈이 안 쌓인다.
//   5. 같은 셰이더 하나로 바위, 지면(바람 0), 풀(바람 켬, 양면) 머티리얼을 모두 만든다.
Shader "ShaderGallery/Mix/SeasonFoliage"
{
    Properties
    {
        [Header(Triplanar Projection)]
        _TileTex ("타일 텍스처", 2D) = "white" {}
        _Tint ("색조", Color) = (1, 1, 1, 1)
        _TileSize ("타일 크기 (m)", Range(0.1, 10)) = 1
        _BlendSharpness ("경계 날카로움", Range(1, 16)) = 4
        [Enum(World, 0, Object, 1)] _Space ("투영 공간", Float) = 0

        [Header(Wind Sway Foliage)]
        _RootColor ("뿌리 색", Color) = (1, 1, 1, 1)
        _TipColor ("끝 색", Color) = (1, 1, 1, 1)
        [Toggle] _TwoSidedLighting ("양면 조명 (잎)", Float) = 0
        _WindStrength ("바람 세기 (0 이면 안 흔들림)", Range(0, 0.6)) = 0
        _WindSpeed ("바람 속도", Range(0, 4)) = 1.2
        _WindAngle ("바람 방향 (Y 회전, 도)", Range(0, 360)) = 60
        _Gustiness ("돌풍 섞기", Range(0, 1)) = 0.7
        _Flutter ("떨림", Range(0, 0.15)) = 0.03
        _Gust ("돌풍 이벤트 (스크립트, 바람 0 이면 무시)", Range(0, 1)) = 0

        [Header(Surface Wet Snow)]
        [Enum(Wet, 0, Snow, 1)] _Mode ("덮는 재질", Float) = 1
        _Coverage ("덮는 양", Range(0, 1)) = 0.5
        _Storm ("소나기, 눈발 이벤트 (스크립트)", Range(0, 1)) = 0
        _Softness ("경계 부드러움", Range(0.01, 0.6)) = 0.12
        _NoiseScale ("노이즈 크기", Range(0.5, 12)) = 3
        _WetDarkness ("젖음 어둡기", Range(0, 1)) = 0.6
        _Gloss ("광택", Range(0, 1)) = 0.7
        _SnowColor ("눈 색", Color) = (0.92, 0.95, 1, 1)

        [Header(Mix)]
        _TipCatch ("잎 끝 눈 받기", Range(0, 1.5)) = 0
        _SnowDamping ("눈 무게로 덜 흔들림", Range(0, 1)) = 0.6
        _RainRipple ("빗물 파문 세기 (스크립트)", Range(0, 1)) = 0
        _RippleScale ("파문 칸 수 (1 m 당)", Range(0.5, 8)) = 2.5
        _RippleSpeed ("파문 속도", Range(0.1, 4)) = 1.4

        [Header(Render)]
        [Enum(UnityEngine.Rendering.CullMode)] _Cull ("컬링", Float) = 2
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" "Queue" = "Geometry" "RenderPipeline" = "UniversalPipeline" }
        Cull [_Cull]

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

        TEXTURE2D(_TileTex);
        SAMPLER(sampler_TileTex);

        CBUFFER_START(UnityPerMaterial)
            float4 _TileTex_ST;
            float4 _Tint;
            float _TileSize;
            float _BlendSharpness;
            float _Space;
            float4 _RootColor;
            float4 _TipColor;
            float _TwoSidedLighting;
            float _WindStrength;
            float _WindSpeed;
            float _WindAngle;
            float _Gustiness;
            float _Flutter;
            float _Gust;
            float _Mode;
            float _Coverage;
            float _Storm;
            float _Softness;
            float _NoiseScale;
            float _WetDarkness;
            float _Gloss;
            float4 _SnowColor;
            float _TipCatch;
            float _SnowDamping;
            float _RainRipple;
            float _RippleScale;
            float _RippleSpeed;
            float _Cull;
        CBUFFER_END

        #define SG_TEX(name, uv) SAMPLE_TEXTURE2D(name, sampler##name, uv)
        #define SURFACE_NOISE_AMOUNT 0.6
        #define SURFACE_GLINT_CELLS 90.0

        // 지금 덮인 양 (원본 젖음/눈의 coverage 와 같은 식). 정점 단계의 눈 무게에도 쓴다.
        float weatherCoverage()
        {
            return saturate(_Coverage + _Storm * 0.4);
        }

        // ---------------------------------------------------------------
        // [바람 흔들림] 원본 그대로
        // ---------------------------------------------------------------
        float2 windDirection()
        {
            float a = _WindAngle * 0.0174533;
            return float2(sin(a), cos(a));
        }

        float windHash(float2 p)
        {
            float3 q = frac(float3(p.x, p.y, p.x) * 0.1031);
            q = q + dot(q, q.yzx + 33.33);
            return frac((q.x + q.y) * q.z);
        }

        float windNoise(float2 p)
        {
            float2 cell = floor(p);
            float2 f = frac(p);
            f = f * f * (3.0 - 2.0 * f);
            float a = windHash(cell);
            float b = windHash(cell + float2(1.0, 0.0));
            float c = windHash(cell + float2(0.0, 1.0));
            float d = windHash(cell + float2(1.0, 1.0));
            return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
        }

        float windGust(float2 xz, float2 dir, float time)
        {
            float2 p = (xz - dir * (time * _WindSpeed * 0.9)) * 2.0;
            float n = windNoise(p) * 0.65 + windNoise(p * 2.1 + float2(5.2, 1.3)) * 0.35;
            return saturate((n - 0.2) / 0.6);
        }

        float windBendMask(float2 uv)
        {
            float y = saturate(uv.y);
            return y * y;
        }

        float windFlutterPhase(float2 xz, float2 dir, float2 side)
        {
            return dot(xz, side) * 4.5 + dot(xz, dir) * 1.2;
        }

        float3 windVertex(float3 positionOS, float2 uv, float time)
        {
            // 바위와 지면처럼 머티리얼의 바람 세기와 떨림이 모두 0 이면 흔들지 않는다.
            // 돌풍(_Gust)은 스크립트가 씬 전체에 넣는 값이라 더하기 전에 머티리얼 값만으로 판단해야 한다.
            // (돌풍을 더한 뒤 판단하면 돌풍이 불 때 바닥과 바위까지 흔들린다.)
            if (_WindStrength + _Flutter <= 0.0)
                return positionOS;

            // [믹스] 눈 모드에서 덮인 양만큼 바람을 줄인다. 눈 쌓인 풀은 무거워 덜 흔들린다.
            float snowLoad = step(0.5, _Mode) * weatherCoverage() * _SnowDamping;
            float strength = (_WindStrength + 0.4 * _Gust) * (1.0 - snowLoad);
            float flutterAmount = _Flutter * (1.0 - snowLoad);

            float2 dir = windDirection();
            float2 side = float2(-dir.y, dir.x);
            float bend = windBendMask(uv);
            float gust = windGust(positionOS.xz, dir, time);
            float wave = sin(time * _WindSpeed * 2.3 - dot(positionOS.xz, dir) * 2.5);
            float sway = strength * (lerp(0.55, gust, _Gustiness) + 0.15 * wave);
            float t = time * _WindSpeed * 6.5 + windFlutterPhase(positionOS.xz, dir, side);
            float2 flutter = (side * sin(t) + dir * (0.5 * sin(t * 1.7 + 1.3))) * (flutterAmount * (0.5 + gust));
            float2 offset = (dir * sway + flutter) * bend;

            // 길이 보정: 뿌리(y = 0)에서 정점까지 길이는 두고 방향만 기울인다 (원본 그대로).
            float h = positionOS.y;
            float3 lean = float3(offset.x, h, offset.y);
            lean = lean * (abs(h) / max(length(lean), 0.0001));
            return float3(positionOS.x + lean.x, lean.y, positionOS.z + lean.z);
        }

        // ---------------------------------------------------------------
        // [삼평면 투영] 원본 그대로
        // ---------------------------------------------------------------
        float3 triplanarWeights(float3 n, float sharpness)
        {
            float3 w = pow(abs(n), float3(sharpness, sharpness, sharpness));
            return w / max(w.x + w.y + w.z, 0.00001);
        }

        float3 triplanarAlbedo(float3 positionWS, float3 positionOS, float3 normalWS, float3 normalOS)
        {
            float useObject = step(0.5, _Space);
            float3 p = lerp(positionWS, positionOS, useObject) / _TileSize;
            float3 n = lerp(normalWS, normalOS, useObject);
            float3 w = triplanarWeights(n, _BlendSharpness);
            float3 texX = SG_TEX(_TileTex, p.zy).rgb;
            float3 texY = SG_TEX(_TileTex, p.xz).rgb;
            float3 texZ = SG_TEX(_TileTex, p.xy).rgb;
            return (texX * w.x + texY * w.y + texZ * w.z) * _Tint.rgb;
        }

        // ---------------------------------------------------------------
        // [젖음과 눈 쌓임] 원본 그대로
        // ---------------------------------------------------------------
        float surfaceHash(float3 p)
        {
            p = frac(p * 0.1031);
            p = p + dot(p, p.zyx + 31.32);
            return frac((p.x + p.y) * p.z);
        }

        float surfaceValueNoise(float3 p)
        {
            float3 cell = floor(p);
            float3 f = frac(p);
            f = f * f * (3.0 - 2.0 * f);
            float x00 = lerp(surfaceHash(cell + float3(0.0, 0.0, 0.0)), surfaceHash(cell + float3(1.0, 0.0, 0.0)), f.x);
            float x10 = lerp(surfaceHash(cell + float3(0.0, 1.0, 0.0)), surfaceHash(cell + float3(1.0, 1.0, 0.0)), f.x);
            float x01 = lerp(surfaceHash(cell + float3(0.0, 0.0, 1.0)), surfaceHash(cell + float3(1.0, 0.0, 1.0)), f.x);
            float x11 = lerp(surfaceHash(cell + float3(0.0, 1.0, 1.0)), surfaceHash(cell + float3(1.0, 1.0, 1.0)), f.x);
            return lerp(lerp(x00, x10, f.y), lerp(x01, x11, f.y), f.z);
        }

        float surfaceNoise(float3 p)
        {
            float n = surfaceValueNoise(p) * 0.6;
            n = n + surfaceValueNoise(p * 2.03 + float3(11.7, 3.1, 7.9)) * 0.28;
            n = n + surfaceValueNoise(p * 4.01 + float3(5.3, 17.2, 2.4)) * 0.12;
            return saturate((n - 0.2) / 0.6);
        }

        float surfaceCoverMask(float up, float coverage)
        {
            float soft = max(_Softness, 0.001);
            float edge = lerp(1.35 + soft, -1.35 - soft, saturate(coverage));
            return smoothstep(edge - soft, edge + soft, up);
        }

        float surfaceSpecular(float3 n, float3 h, float ndotl, float power)
        {
            return pow(saturate(dot(n, h)), power) * step(0.0, ndotl);
        }

        // ---------------------------------------------------------------
        // [믹스] 빗물 파문: 월드 xz 를 칸으로 나눠 칸마다 동심원 하나가 퍼졌다 사라진다 (두 층을 엇갈려 겹친다).
        // 칸 위치와 시작 박자는 해시로 정해 칸마다 다르다. 높이만 구하고 법선은 옆 칸과의 차이로 구한다(물결 수면, 물가 거품과 같은 방식).
        // ---------------------------------------------------------------
        float rippleHeight(float2 p, float time)
        {
            float h = 0.0;
            [unroll] for (int layer = 0; layer < 2; layer++)
            {
                float2 q = p * _RippleScale + layer * float2(0.37, 0.71);
                float2 cell = floor(q);
                float2 f = q - cell;
                float3 seed = float3(cell, layer * 7.0);
                float r1 = surfaceHash(seed);
                float r2 = surfaceHash(seed + float3(5.1, 2.3, 0.0));
                float r3 = surfaceHash(seed + float3(1.7, 9.2, 3.0));
                float r4 = surfaceHash(seed + float3(8.3, 4.4, 6.0));
                // 비가 셀수록 파문이 생기는 칸이 많아진다.
                float present = step(r4, 0.25 + 0.75 * _RainRipple);
                float2 center = 0.25 + 0.5 * float2(r1, r2);
                float phase = frac(time * _RippleSpeed * (0.7 + 0.6 * r3) + r3);
                float d = length(f - center);
                float x = (d - phase * 0.4) * 30.0;
                // 고리 하나: 반지름 근처만 솟는다. 퍼질수록 낮아져 사라진다.
                float ring = (cos(clamp(x, -PI, PI)) + 1.0) * 0.5;
                h += ring * (1.0 - phase) * (1.0 - phase) * present;
            }
            return h;
        }

        // 파문 기울기 (높이를 x, z 로 미분한 값, 1 m 당)
        float2 rippleSlope(float2 p, float time)
        {
            float e = 0.01;
            float h = rippleHeight(p, time);
            return float2(rippleHeight(p + float2(e, 0.0), time) - h, rippleHeight(p + float2(0.0, e), time) - h) / e;
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
            float3 positionOS : TEXCOORD1;   // 밀기 전 위치. 노이즈와 오브젝트 공간 투영이 잎에 붙어 있게 한다.
            float3 positionWS : TEXCOORD2;   // 민 뒤의 위치. 조명과 그림자, 월드 투영에 쓴다.
            float3 normalWS : TEXCOORD3;
            float3 normalOS : TEXCOORD4;
            UNITY_VERTEX_INPUT_INSTANCE_ID
            UNITY_VERTEX_OUTPUT_STEREO
        };

        Varyings vert(Attributes v)
        {
            Varyings o;
            UNITY_SETUP_INSTANCE_ID(v);
            UNITY_TRANSFER_INSTANCE_ID(v, o);
            UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
            // [바람] 모든 패스(그림자 포함)가 같은 정점 함수를 불러 그림자도 함께 흔들린다.
            float3 p = windVertex(v.positionOS.xyz, v.uv, _Time.y);
            o.positionWS = TransformObjectToWorld(p);
            o.positionCS = TransformWorldToHClip(o.positionWS);
            o.normalWS = TransformObjectToWorldNormal(v.normalOS);
            o.normalOS = v.normalOS;
            o.positionOS = v.positionOS.xyz;
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
            #pragma multi_compile_fog

            float4 frag(Varyings v, bool isFrontFace : SV_IsFrontFace) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(v);
                float3 n = normalize(v.normalWS);
                float3 viewWS = GetWorldSpaceNormalizeViewDir(v.positionWS);
                Light light = GetMainLight(TransformWorldToShadowCoord(v.positionWS), v.positionWS, half4(1, 1, 1, 1));
                float3 lightColor = light.color * light.shadowAttenuation;
                float ndotl = dot(n, light.direction);
                float3 lighting = lightColor * saturate(ndotl) + SampleSH(n);
                // [바람] 원본의 양면 조명: 빛이 잎 뒷면에서 와도 똑같이 밝힌다.
                lighting += _TwoSidedLighting * lightColor * saturate(-ndotl);
                float3 h = normalize(light.direction + viewWS);

                // 1. [삼평면 투영] 마른 표면 색. [바람]의 뿌리→끝 색을 곱한다.
                float3 albedo = triplanarAlbedo(v.positionWS, v.positionOS, n, v.normalOS);
                albedo *= lerp(_RootColor.rgb, _TipColor.rgb, saturate(v.uv.y));
                float3 dry = albedo * lighting + lightColor * surfaceSpecular(n, h, ndotl, 12.0) * 0.04;

                // 2. [젖음/눈] 윗면 마스크 + 노이즈. [믹스] 잎 끝(uv.y)도 눈을 받게 위쪽 값을 올린다.
                float coverage = weatherCoverage();
                float noise = surfaceNoise(v.positionOS * _NoiseScale);
                float up = n.y + _TipCatch * saturate(v.uv.y);
                float mask = surfaceCoverMask(up + (noise - 0.5) * SURFACE_NOISE_AMOUNT, coverage);

                // 3. [젖음] 어두워지고 하이라이트가 좁고 강해진다. 프레넬로 주변을 비춘다.
                float3 wetAlbedo = lerp(albedo, albedo * albedo * 0.8, _WetDarkness) * lerp(1.0, 0.4, _WetDarkness);
                float wetPower = exp2(lerp(5.0, 10.0, _Gloss));
                float wetStrength = lerp(0.3, 3.0, _Gloss);
                float3 ambient = max(lighting - lightColor * saturate(ndotl), float3(0.0, 0.0, 0.0));

                // [믹스] 빗물 파문: 비가 오는 동안 젖은 윗면의 법선을 동심원으로 흔든다. 반사광과 하늘 반사에 고리가 비친다.
                float isSnow = step(0.5, _Mode);
                float rippleMask = _RainRipple * (1.0 - isSnow) * saturate((n.y - 0.6) / 0.3);
                float3 wetN = n;
                if (rippleMask > 0.001)
                {
                    float2 slope = rippleSlope(v.positionWS.xz, _Time.y);
                    wetN = normalize(n + float3(-slope.x, 0.0, -slope.y) * (0.006 * rippleMask));
                }
                float fresnel = pow(1.0 - saturate(dot(wetN, viewWS)), 4.0);
                float3 wet = wetAlbedo * lighting + lightColor * surfaceSpecular(wetN, h, ndotl, wetPower) * wetStrength + ambient * fresnel * _Gloss;
                // 고리가 기운 만큼 하늘빛을 더 비춰, 해가 가려진 흐린 날에도 파문이 보이게 한다.
                wet += ambient * (1.0 - dot(wetN, n)) * 40.0 * _Gloss;

                // 4. [눈] 흰 색 + 알갱이 반짝임 (원본 그대로)
                float3 grain = floor(v.positionOS * SURFACE_GLINT_CELLS);
                float3 jitter = float3(surfaceHash(grain), surfaceHash(grain + float3(17.0, 5.0, 3.0)), surfaceHash(grain + float3(7.0, 29.0, 13.0))) - 0.5;
                float3 glintN = normalize(n + jitter * 0.9);
                float glintPick = step(0.8, surfaceHash(grain + float3(3.0, 11.0, 23.0)));
                float glint = glintPick * surfaceSpecular(glintN, h, ndotl, 300.0) * lerp(0.0, 6.0, _Gloss);
                float3 snow = _SnowColor.rgb * lighting + lightColor * (surfaceSpecular(n, h, ndotl, 10.0) * 0.08 + glint);

                float3 cover = lerp(wet, snow, isSnow);
                float3 color = lerp(dry, cover, mask);
                // 비가 오면 스크립트가 켜는 안개를 받는다.
                float fogFactor = ComputeFogFactor(TransformWorldToHClip(v.positionWS).z);
                return float4(MixFog(color, fogFactor), 1.0);
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

            void fragNormals(Varyings v, bool isFrontFace : SV_IsFrontFace, out float4 outNormalWS : SV_Target0
            #ifdef _WRITE_RENDERING_LAYERS
                , out uint outRenderingLayers : SV_Target1
            #endif
            )
            {
                float3 normalWS = normalize(v.normalWS);
                // 양면 잎의 뒷면은 법선을 뒤집어 넘긴다 (SSAO 가 뒷면을 이상하게 어둡히지 않게).
                normalWS = isFrontFace ? normalWS : -normalWS;
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

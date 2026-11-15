// [믹스 3] 불타며 사라지기 - 몸체 (URP 17, HLSL)
// 디졸브 + 노이즈 불꽃 + 자체 발광(HDR).
//
// 섞은 지점
//   1. [디졸브] 노이즈 < 임계값 인 곳을 잘라 낸다 (원본 그대로).
//   2. [노이즈 불꽃] 흐르는 두 층 노이즈로 타는 띠의 폭을 흔든다. 경계가 불처럼 일렁이며 위로 번진다.
//   3. [노이즈 불꽃] 타는 띠 안쪽(구멍 쪽)이 가장 뜨겁게 노랑, 바깥으로 주황, 빨강, 마지막에 그을린 숯색이 된다.
//   4. [자체 발광] 띠 색에 HDR 세기를 곱해 Bloom 으로 번진다.
// 불꽃 혀는 같은 렌더러의 두 번째 머티리얼(BurningDissolveFlame.shader)이 그린다.
Shader "ShaderGallery/Mix/BurningDissolve"
{
    Properties
    {
        [Header(Surface)]
        _BaseColor ("기본 색", Color) = (0.75, 0.78, 0.82, 1)
        _CharColor ("그을음 색", Color) = (0.06, 0.04, 0.035, 1)

        [Header(Dissolve)]
        _Threshold ("임계값 (타는 정도)", Range(0, 1)) = 0.35
        _NoiseScale ("노이즈 크기", Range(0.5, 12)) = 4
        _Sweep ("쓸기 (위에서부터)", Range(0, 1)) = 0.35
        _BurnWidth ("타는 띠 폭", Range(0.01, 0.4)) = 0.1
        _CharWidth ("그을음 폭", Range(0, 0.5)) = 0.12

        [Header(Fire Noise Flame)]
        [NoScaleOffset] _NoiseTex ("불꽃 노이즈 (sRGB 끔)", 2D) = "linearGrey" {}
        _CoreColor ("속 색", Color) = (1, 0.902, 0.502, 1)
        _MidColor ("가운데 색", Color) = (1, 0.502, 0.0784, 1)
        _EdgeColor ("가장자리 색", Color) = (0.851, 0.1373, 0.0392, 1)
        _Intensity ("발광 세기 (HDR)", Range(0, 10)) = 4
        _FlowSpeed ("흐름 속도", Range(0, 3)) = 1
        _FireNoiseScale ("불꽃 노이즈 크기", Range(0.5, 6)) = 1.6
        _FlameShell ("불꽃 껍데기 두께", Range(0, 0.5)) = 0.1
        _FlameReach ("불꽃 퍼짐", Range(0.02, 0.5)) = 0.18
        _EdgeSoftness ("불꽃 가장자리 부드러움", Range(0.01, 0.4)) = 0.08
    }

    SubShader
    {
        Tags { "RenderType" = "TransparentCutout" "Queue" = "AlphaTest" "RenderPipeline" = "UniversalPipeline" }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
        #include "BurningDissolveCore.hlsl"

        struct Attributes
        {
            float4 positionOS : POSITION;
            float3 normalOS : NORMAL;
            UNITY_VERTEX_INPUT_INSTANCE_ID
        };

        struct Varyings
        {
            float4 positionCS : SV_POSITION;
            float3 positionOS : TEXCOORD0;
            float3 positionWS : TEXCOORD1;
            float3 normalWS : TEXCOORD2;
            float3 normalOS : TEXCOORD3;
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
            o.positionOS = v.positionOS.xyz;
            o.normalOS = v.normalOS;
            return o;
        }

        // 그림자와 깊이 패스도 같은 자리를 잘라 내야 구멍으로 빛이 새고 그림자에도 구멍이 난다.
        void clipDissolve(Varyings v)
        {
            clip(dissolveField(v.positionOS) - dissolveCut());
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

            float4 frag(Varyings v) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(v);
                float3 normalWS = normalize(v.normalWS);
                Light light = GetMainLight(TransformWorldToShadowCoord(v.positionWS), v.positionWS, half4(1, 1, 1, 1));
                float3 lighting = light.color * light.shadowAttenuation * saturate(dot(normalWS, light.direction)) + SampleSH(normalWS);
                float3 lit = _BaseColor.rgb * lighting;

                // 1. [디졸브] 잘라 내기
                float field = dissolveField(v.positionOS);
                float cut = dissolveCut();
                clip(field - cut);

                // 2. [노이즈 불꽃] 흐르는 노이즈로 띠 폭을 흔든다. 노이즈가 밝은 곳은 불이 멀리까지 번져 위로 혀가 선다.
                float fire = fireNoise(v.positionOS, v.normalOS, _Time.y);
                float width = _BurnWidth * (0.5 + fire);
                float d = field - cut;
                float active = saturate(_Threshold * 20.0);

                // 3. 구멍에 가까울수록 뜨겁다. heat 1 = 구멍 바로 옆.
                float heat = (1.0 - saturate(d / max(width, 0.0001))) * active;
                // 그을음: 타는 띠보다 조금 더 넓게 숯색으로 어둡게 한다.
                float charT = (1.0 - saturate(d / max(width + _CharWidth, 0.0001))) * active;
                float3 color = lerp(lit, _CharColor.rgb * lighting, smoothstep(0.0, 0.6, charT));

                // 4. [노이즈 불꽃 색] + [자체 발광 HDR] 조명과 무관하게 빛난다. 그늘에서도 불은 밝다.
                float3 glow = fireGradient(heat) * _Intensity;
                color = lerp(color, glow, smoothstep(0.0, 0.2, heat));
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
            #pragma fragment fragClip
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

            float4 fragClip(Varyings v) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(v);
                clipDissolve(v);
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
                UNITY_SETUP_INSTANCE_ID(v);
                clipDissolve(v);
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
                UNITY_SETUP_INSTANCE_ID(v);
                clipDissolve(v);
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

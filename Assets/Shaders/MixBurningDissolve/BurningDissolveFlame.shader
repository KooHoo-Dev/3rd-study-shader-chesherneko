// [믹스 3] 불타며 사라지기 - 불꽃 껍데기 (URP 17, HLSL)
// 몸체(BurningDissolve.shader)와 같은 렌더러에 두 번째 머티리얼로 넣는다.
//
// 섞은 지점
//   - [껍데기] 메시를 법선 방향으로 조금 부풀려 한 번 더 그린다. 표면 바깥 공간에 불꽃이 설 자리가 생긴다.
//   - [디졸브] 같은 노이즈와 임계값으로, 지금 타고 있는 경계 근처만 마스크로 남긴다.
//     원본 노이즈 불꽃의 'UV 로 만든 불꽃 모양 마스크' 자리를 '디졸브 경계까지의 거리' 가 대신한다.
//   - [노이즈 불꽃] 원본 그대로 흐르는 두 층을 곱해 마스크와 함께 깎고, heat 로 색을 고른다.
//   - [자체 발광] 더하기 혼합 + HDR 세기라 Bloom 으로 번진다.
Shader "ShaderGallery/Mix/BurningDissolveFlame"
{
    Properties
    {
        [Header(Surface)]
        _BaseColor ("기본 색 (몸체용, 여기서는 안 씀)", Color) = (0.75, 0.78, 0.82, 1)
        _CharColor ("그을음 색 (몸체용, 여기서는 안 씀)", Color) = (0.06, 0.04, 0.035, 1)

        [Header(Dissolve  same values as body)]
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
        Tags { "RenderType" = "Transparent" "Queue" = "Transparent" "RenderPipeline" = "UniversalPipeline" "IgnoreProjector" = "True" }

        Pass
        {
            Name "Flame"
            Tags { "LightMode" = "UniversalForward" }

            // [노이즈 불꽃] 원본과 같은 더하기 혼합. 양면을 그려 구멍 너머 안쪽 불꽃도 보인다.
            Blend SrcAlpha One
            ZWrite Off
            Cull Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_instancing

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
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
                float3 positionOS : TEXCOORD0;   // 부풀리기 전 위치. 몸체와 같은 노이즈 값을 읽는다.
                float3 normalOS : TEXCOORD1;
                UNITY_VERTEX_INPUT_INSTANCE_ID
                UNITY_VERTEX_OUTPUT_STEREO
            };

            Varyings vert(Attributes v)
            {
                Varyings o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_TRANSFER_INSTANCE_ID(v, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                // 법선 쪽으로 부풀리고 위로 조금 띄운다. 불꽃이 표면에서 떨어져 위로 서 보인다.
                float3 p = v.positionOS.xyz + normalize(v.normalOS) * _FlameShell + float3(0.0, _FlameShell * 0.5, 0.0);
                o.positionCS = TransformObjectToHClip(p);
                o.positionOS = v.positionOS.xyz;
                o.normalOS = v.normalOS;
                return o;
            }

            float4 frag(Varyings v) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(v);

                // 1. [디졸브] 타는 경계까지 거리. 경계 양쪽 _FlameReach 안에서만 불이 선다. 원본 불꽃의 모양 마스크 자리다.
                float d = dissolveField(v.positionOS) - dissolveCut();
                float near = 1.0 - saturate(abs(d) / _FlameReach);
                float mask = near * near * burnActive();

                // 2. [노이즈 불꽃] 흐르는 두 층 노이즈 (원본: layerA * layerB * 2)
                float noise = fireNoise(v.positionOS, v.normalOS, _Time.y);

                // 3. [노이즈 불꽃] 깎기와 색 (원본 그대로)
                float fire = mask * (noise + 0.3) * 2.5;
                float flame = smoothstep(FIRE_FLAME_CUT - _EdgeSoftness, FIRE_FLAME_CUT + _EdgeSoftness, fire);
                float heat = saturate((fire - FIRE_FLAME_CUT) / 2.0);

                // 4. [자체 발광] HDR 세기. 더하기 혼합이라 알파는 더할 양이다.
                return float4(fireGradient(heat) * _Intensity, flame);
            }
            ENDHLSL
        }
    }
}

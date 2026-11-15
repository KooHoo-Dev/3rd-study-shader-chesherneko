// [믹스 5 추가] 3D 비와 눈 (URP 17, HLSL)
// 씬 공간 상자 안에 흩뿌린 방울 수천 개(RainDrops 메시, 방울 하나 = 사각형 하나)를 정점 셰이더가 떨어뜨리고 카메라 쪽으로 세운다.
// 화면에 덧그린 판이 아니라 실제 공간에 있어서 바위와 풀 뒤로 가려지고, 멀수록 가늘어지고, 땅(상자 바닥)에서 사라진다.
//
// 같은 방울을 모드 하나(_SnowMode)로 비와 눈 두 가지로 그린다.
//   - 비 (0): 빠르게 떨어지고, 떨어지는 축을 중심으로만 카메라를 향해 도는 가늘고 긴 빗줄기
//   - 눈 (1): 천천히 떨어지며 좌우로 흩날리고, 카메라를 정면으로 보는 둥근 눈송이
// 날씨 슬라이더가 양이 0 인 가운데에서만 모드를 바꾸므로 비가 눈으로 바뀌는 순간은 보이지 않는다.
//
// 갤러리에서 빌린 기법
//   - 정점 변형 (물결 수면, 바람 흔들림): 정점 위치를 시간으로 옮긴다. 여기서는 떨어뜨리고 상자 높이로 감싼다(frac).
//   - 바람 흔들림의 바람 방향과 떨림     : 같은 각도(_WindAngle)로 비를 기울이고, 눈송이는 방울마다 박자가 다른 사인으로 흩날린다.
//   - 해시                              : 방울마다 고정된 난수(uv2)로 속도, 크기, 있고 없음을 정한다.
//   - fwidth 류 안티에일리어싱 사고방식 : 멀리 있는 방울이 1 픽셀보다 작아지면 1 픽셀로 키우고 그만큼 알파를 낮춰 깜빡임을 막는다.
//
// 양(_RainAmount)이 늘면 그려지는 방울 수가 는다. 날씨 슬라이더 스크립트가 넣는다.
Shader "ShaderGallery/Mix/RainStreaks"
{
    Properties
    {
        _RainAmount ("양 (스크립트)", Range(0, 1)) = 0.8
        [Enum(Rain, 0, Snow, 1)] _SnowMode ("모드 (스크립트)", Float) = 0
        _BoxHeight ("상자 높이 (m, 메시와 같게)", Float) = 9
        _WindAngle ("바람 방향 (Y 회전, 도)", Range(0, 360)) = 60
        _WindSlant ("바람 기울기", Range(0, 0.6)) = 0.15
        _NearFade ("가까운 방울 지우기 (m)", Range(0.1, 3)) = 1.2

        [Header(Rain)]
        _Color ("빗줄기 색", Color) = (0.82, 0.88, 0.95, 1)
        _Opacity ("빗줄기 불투명도", Range(0, 1)) = 0.45
        _Speed ("빗줄기 속도 (m/s)", Range(1, 20)) = 9
        _Length ("빗줄기 길이 (m)", Range(0.05, 1.5)) = 0.45
        _Width ("빗줄기 폭 (m)", Range(0.001, 0.03)) = 0.006

        [Header(Snow)]
        _SnowColor ("눈송이 색", Color) = (0.95, 0.97, 1, 1)
        _SnowOpacity ("눈송이 불투명도", Range(0, 1)) = 0.9
        _SnowSpeed ("눈송이 속도 (m/s)", Range(0.2, 4)) = 1.1
        _FlakeSize ("눈송이 크기 (m)", Range(0.005, 0.1)) = 0.025
        _SnowSway ("흩날림 (m)", Range(0, 0.6)) = 0.25
        _SnowDrift ("바람에 밀림 배율", Range(0, 6)) = 2.5
    }

    SubShader
    {
        Tags { "RenderType" = "Transparent" "Queue" = "Transparent" "RenderPipeline" = "UniversalPipeline" "IgnoreProjector" = "True" }

        Pass
        {
            Name "Precipitation"
            Tags { "LightMode" = "UniversalForward" }

            Blend SrcAlpha OneMinusSrcAlpha
            ZWrite Off
            Cull Off

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float _RainAmount;
                float _SnowMode;
                float _BoxHeight;
                float _WindAngle;
                float _WindSlant;
                float _NearFade;
                float4 _Color;
                float _Opacity;
                float _Speed;
                float _Length;
                float _Width;
                float4 _SnowColor;
                float _SnowOpacity;
                float _SnowSpeed;
                float _FlakeSize;
                float _SnowSway;
                float _SnowDrift;
            CBUFFER_END

            struct Attributes
            {
                float3 positionOS : POSITION;   // 방울의 처음 위치. 한 방울의 네 정점이 모두 같다.
                float2 corner : TEXCOORD0;      // x: -1 / 1 (좌우), y: 0 (아래) / 1 (위)
                float2 random : TEXCOORD1;      // 방울마다 고정된 난수 두 개
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 corner : TEXCOORD0;
                float alpha : TEXCOORD1;
                float fogFactor : TEXCOORD2;
                float3 lightTint : TEXCOORD3;
            };

            Varyings vert(Attributes v)
            {
                Varyings o = (Varyings)0;
                float r1 = v.random.x;
                float r2 = v.random.y;
                float isSnow = step(0.5, _SnowMode);

                // 양만큼만 방울을 그린다. 빠지는 방울은 클립 공간 밖으로 보내 그리지 않는다.
                if (r1 > _RainAmount)
                {
                    o.positionCS = float4(2.0, 2.0, 2.0, 1.0);
                    return o;
                }

                // 바람 방향 (바람 흔들림 원본과 같은 각도 규칙: 0 = +Z, 90 = +X)
                float a = _WindAngle * 0.0174533;
                float2 windXZ = float2(sin(a), cos(a)) * _WindSlant;
                float3 fallDir = normalize(float3(windXZ.x, -1.0, windXZ.y));

                // 1. 정점 변형: 시간만큼 떨어뜨리고 상자 높이로 감싼다. 바닥(0)을 지나면 꼭대기에서 다시 나온다.
                //    frac 으로 감싸 오래 켜 두어도 큰 수가 쌓이지 않는다. 눈은 느리고 방울마다 속도 차이가 크다.
                float speed = isSnow > 0.5 ? _SnowSpeed * (0.6 + 0.8 * r2) : _Speed * (0.85 + 0.3 * r2);
                float fallen = frac(v.positionOS.y / _BoxHeight - frac(_Time.y * speed / _BoxHeight)) * _BoxHeight;
                // 떨어진 만큼 바람 쪽으로 밀린다. 높이(fallen)로 정하므로 감쌀 때 옆으로 튀지 않는다. 가벼운 눈은 더 많이 밀린다.
                float drift = lerp(1.0, _SnowDrift, isSnow);
                float3 p = float3(v.positionOS.x, fallen, v.positionOS.z) + float3(windXZ.x, 0.0, windXZ.y) * ((_BoxHeight - fallen) * drift);

                // [눈] 흩날림: 방울마다 박자와 크기가 다른 사인으로 좌우, 앞뒤로 흔든다 (바람 흔들림의 떨림과 같은 생각).
                float t = _Time.y;
                float3 sway = float3(sin(t * (0.9 + 0.8 * r2) + r1 * 40.0), 0.0, cos(t * (0.7 + 0.6 * r1) + r2 * 40.0));
                p += sway * (_SnowSway * (0.5 + r2)) * isSnow;

                float3 centerWS = TransformObjectToWorld(p);
                float3 toCam = _WorldSpaceCameraPos - centerWS;
                float dist = length(toCam);

                // 이 거리에서 화면 1 픽셀이 몇 m 인지. 방울이 이보다 작아지면 1 픽셀로 키우고 알파를 낮춘다.
                float pixelSize = 2.0 * dist / (abs(UNITY_MATRIX_P._m11) * _ScreenParams.y);

                float3 posWS;
                float sizeFade;
                if (isSnow > 0.5)
                {
                    // 2-눈. 카메라를 정면으로 보는 둥근 판 (뷰 행렬의 오른쪽, 위쪽 축으로 펼친다)
                    float3 right = UNITY_MATRIX_V._m00_m01_m02;
                    float3 up = UNITY_MATRIX_V._m10_m11_m12;
                    float flake = _FlakeSize * (0.6 + 0.8 * r2);
                    float size = max(flake, pixelSize * 1.5);
                    sizeFade = (flake / size) * (flake / size);
                    posWS = centerWS + right * (v.corner.x * size) + up * ((v.corner.y * 2.0 - 1.0) * size);
                }
                else
                {
                    // 2-비. 떨어지는 축을 중심으로만 돌아 카메라를 향하는 가늘고 긴 판
                    float3 axis = -fallDir;
                    float3 side = normalize(cross(axis, toCam / max(dist, 0.0001)));
                    float width = max(_Width, pixelSize);
                    sizeFade = _Width / width;
                    float length01 = _Length * (0.7 + 0.6 * r2);
                    posWS = centerWS + side * (v.corner.x * width) + axis * (v.corner.y * length01);
                }

                o.positionCS = TransformWorldToHClip(posWS);
                o.corner = v.corner;

                // 카메라 바로 앞 방울은 화면을 크게 가리므로 지우고, 땅 바로 위에서도 살짝 옅게 해 땅에 박히는 끝을 숨긴다.
                float nearFade = saturate((dist - 0.3) / _NearFade);
                float groundFade = saturate(fallen / 0.3);
                float opacity = lerp(_Opacity, _SnowOpacity, isSnow);
                o.alpha = opacity * sizeFade * nearFade * groundFade;

                // 하늘빛(환경광)과 해의 색을 받는다. 눈은 빛을 더 많이 되돌려 해에 더 밝아진다.
                float3 baseColor = lerp(_Color.rgb, _SnowColor.rgb, isSnow);
                o.lightTint = baseColor * (SampleSH(float3(0, 1, 0)) + GetMainLight().color * lerp(0.35, 0.7, isSnow));
                o.fogFactor = ComputeFogFactor(o.positionCS.z);
                return o;
            }

            float4 frag(Varyings v) : SV_Target
            {
                float alpha;
                if (_SnowMode > 0.5)
                {
                    // 눈송이: 가운데가 진하고 가장자리가 부드러운 원
                    float2 c = float2(v.corner.x, v.corner.y * 2.0 - 1.0);
                    alpha = v.alpha * smoothstep(1.0, 0.35, length(c));
                }
                else
                {
                    // 빗줄기: 아래(머리)는 진하고 위(꼬리)로 갈수록 옅다. 가로는 가운데가 진한 둥근 단면.
                    float along = pow(1.0 - v.corner.y, 1.5);
                    float across = 1.0 - v.corner.x * v.corner.x;
                    alpha = v.alpha * along * across;
                }
                return float4(MixFog(v.lightTint, v.fogFactor), alpha);
            }
            ENDHLSL
        }
    }
}

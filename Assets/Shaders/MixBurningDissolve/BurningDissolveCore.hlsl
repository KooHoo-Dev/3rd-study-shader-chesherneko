// [믹스 3] 불타며 사라지기 = 디졸브 + 노이즈 불꽃 + 자체 발광(HDR) 의 공통 부분.
// 몸체 셰이더(BurningDissolve.shader)와 불꽃 껍데기 셰이더(BurningDissolveFlame.shader)가 함께 include 한다.
// 두 셰이더가 같은 노이즈, 같은 임계값을 써야 불꽃이 정확히 타는 경계 위에 붙는다.
//
// 원본 (Shader Gallery)
//   - 디졸브 (dissolve-edge-glow) : 3D 값 노이즈와 임계값으로 잘라 내고, 임계값 바로 위 띠를 발광 색으로 바꾼다.
//   - 노이즈 불꽃 (fire-noise-flame): 흐르는 노이즈 두 층을 곱하고, 마스크로 깎은 뒤 빨강→주황→노랑을 입힌다.
//   - 자체 발광 (HDR)            : 색에 1 보다 큰 세기를 곱해 Bloom 이 번지게 한다.
#ifndef BURNING_DISSOLVE_CORE_INCLUDED
#define BURNING_DISSOLVE_CORE_INCLUDED

TEXTURE2D(_NoiseTex);
SAMPLER(sampler_NoiseTex);

// 두 셰이더의 Properties 가 같아 CBUFFER 도 같다 (SRP Batcher 호환).
CBUFFER_START(UnityPerMaterial)
    float4 _BaseColor;
    float4 _CharColor;
    float _Threshold;
    float _NoiseScale;
    float _Sweep;
    float _BurnWidth;
    float _CharWidth;
    float4 _CoreColor;
    float4 _MidColor;
    float4 _EdgeColor;
    float _Intensity;
    float _FlowSpeed;
    float _FireNoiseScale;
    float _FlameShell;
    float _FlameReach;
    float _EdgeSoftness;
CBUFFER_END

#define SG_TEX(name, uv) SAMPLE_TEXTURE2D(name, sampler##name, uv)
#define FIRE_FLAME_CUT 0.5

// ---------------------------------------------------------------
// [디졸브] 원본 그대로: 해시, 3D 값 노이즈, 세 층 노이즈
// ---------------------------------------------------------------
float dissolveHash(float3 p)
{
    p = frac(p * 0.1031);
    p = p + dot(p, p.zyx + 31.32);
    return frac((p.x + p.y) * p.z);
}

float dissolveValueNoise(float3 p)
{
    float3 cell = floor(p);
    float3 f = frac(p);
    f = f * f * (3.0 - 2.0 * f);
    float x00 = lerp(dissolveHash(cell + float3(0.0, 0.0, 0.0)), dissolveHash(cell + float3(1.0, 0.0, 0.0)), f.x);
    float x10 = lerp(dissolveHash(cell + float3(0.0, 1.0, 0.0)), dissolveHash(cell + float3(1.0, 1.0, 0.0)), f.x);
    float x01 = lerp(dissolveHash(cell + float3(0.0, 0.0, 1.0)), dissolveHash(cell + float3(1.0, 0.0, 1.0)), f.x);
    float x11 = lerp(dissolveHash(cell + float3(0.0, 1.0, 1.0)), dissolveHash(cell + float3(1.0, 1.0, 1.0)), f.x);
    return lerp(lerp(x00, x10, f.y), lerp(x01, x11, f.y), f.z);
}

float dissolveNoise(float3 p)
{
    float n = dissolveValueNoise(p) * 0.6;
    n = n + dissolveValueNoise(p * 2.03 + float3(11.7, 3.1, 7.9)) * 0.28;
    n = n + dissolveValueNoise(p * 4.01 + float3(5.3, 17.2, 2.4)) * 0.12;
    return saturate((n - 0.2) / 0.6);
}

// 디졸브 값. 쓸기가 크면 위쪽부터 사라진다 (원본과 같다).
float dissolveField(float3 positionOS)
{
    float noise = dissolveNoise(positionOS * _NoiseScale);
    return lerp(noise, saturate(0.5 - positionOS.y), _Sweep);
}

// 1 에서 하나도 남지 않게 살짝 넘긴다 (원본과 같다).
float dissolveCut()
{
    return _Threshold * 1.01;
}

// 타는 중인지. 임계값이 0(멀쩡함)이나 1(다 탐) 근처면 불이 꺼진다.
float burnActive()
{
    return saturate(_Threshold * 20.0) * saturate((1.0 - _Threshold) * 10.0);
}

// ---------------------------------------------------------------
// [노이즈 불꽃] 흐르는 노이즈 두 층 곱하기.
// 원본은 Quad 의 UV 로 읽지만, 여기서는 3D 물체 위에 붙여야 해서 오브젝트 공간 위치를 세 평면에 투영해 읽는다.
// 옆면 두 평면(XY, ZY)은 v 가 위쪽(+y)이라 원본처럼 v 로 흘리면 불길이 위로 오른다.
// ---------------------------------------------------------------
float fireLayers(float2 uv, float t)
{
    float2 noiseUV = uv * _FireNoiseScale;
    float layerA = SG_TEX(_NoiseTex, noiseUV + float2(0.0, frac(-t * 0.6))).r;
    float layerB = SG_TEX(_NoiseTex, noiseUV * 2.0 + float2(0.37, frac(-t * 2.4))).r;
    return layerA * layerB * 2.0;
}

float fireNoise(float3 positionOS, float3 normalOS, float time)
{
    float t = time * _FlowSpeed;
    float3 w = abs(normalOS);
    w = w * w;
    w = w / max(w.x + w.y + w.z, 0.0001);
    float nx = fireLayers(positionOS.zy, t);
    float ny = fireLayers(positionOS.xz + float2(0.19, 0.53), t);
    float nz = fireLayers(positionOS.xy + float2(0.61, 0.27), t);
    return nx * w.x + ny * w.y + nz * w.z;
}

// [노이즈 불꽃] 원본의 색 그라데이션: 가장자리 빨강 → 가운데 주황 → 속 노랑
float3 fireGradient(float heat)
{
    float3 color = lerp(_EdgeColor.rgb, _MidColor.rgb, smoothstep(0.0, 0.3, heat));
    return lerp(color, _CoreColor.rgb, smoothstep(0.5, 1.0, heat));
}

#endif

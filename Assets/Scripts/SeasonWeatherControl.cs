using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// [믹스 5] 계절이 바뀌는 숲 데모용. 슬라이더 하나로 날씨를 직접 조절한다.
///   왼쪽 끝 = 비(젖음 최대), 가운데 = 맑음, 오른쪽 끝 = 눈(눈 최대)
/// 가운데(덮는 양 0)를 지날 때만 젖음/눈 모드가 바뀌므로 모드가 바뀌는 순간이 화면에 보이지 않는다.
/// 슬라이더 값을 바로 넣지 않고 부드럽게 따라가게 해, 끝에서 끝으로 끌어도 툭 바뀌지 않는다.
///
/// 비 쪽에서는 함께 바뀌는 것:
///   - 3D 빗방울(RainStreaks 셰이더)의 개수
///   - 젖은 윗면의 빗물 파문(SeasonFoliage 셰이더의 _RainRipple)
///   - 안개 짙기, 해의 밝기 (흐린 날)
/// 눈 쪽에서는 같은 RainStreaks 렌더러가 눈송이 모드로 바뀌어 내리고, 안개와 어두워짐은 비보다 약하다.
/// 셰이더 값은 MaterialPropertyBlock 으로 넣어 머티리얼 에셋은 바뀌지 않는다. 안개와 빛은 끄면 원래대로 돌린다.
/// </summary>
public class SeasonWeatherControl : MonoBehaviour
{
    static readonly int ModeId = Shader.PropertyToID("_Mode");
    static readonly int CoverageId = Shader.PropertyToID("_Coverage");
    static readonly int GustId = Shader.PropertyToID("_Gust");
    static readonly int RainRippleId = Shader.PropertyToID("_RainRipple");
    static readonly int RainAmountId = Shader.PropertyToID("_RainAmount");
    static readonly int SnowModeId = Shader.PropertyToID("_SnowMode");

    [Header("UI")]
    [Tooltip("날씨 슬라이더 (-1 비 ~ 0 맑음 ~ 1 눈)")] public Slider slider;
    [Tooltip("지금 날씨를 보여 줄 글자 (비워도 된다)")] public Text label;

    [Header("덮기")]
    [Tooltip("슬라이더 끝에서의 덮는 양")] [Range(0f, 1f)] public float maxCoverage = 0.85f;
    [Tooltip("슬라이더를 따라가는 시간(초). 0 이면 바로 바뀐다")] public float smoothTime = 0.3f;

    [Header("바람")]
    [Tooltip("간격마다 돌풍을 일으킨다 (풀 머티리얼만 반응한다)")] public bool autoGust = true;
    [Tooltip("돌풍 간격(초)")] public float gustInterval = 6f;

    [Header("비")]
    [Tooltip("3D 비/눈 렌더러 (RainStreaks 셰이더). 비 쪽은 빗줄기, 눈 쪽은 눈송이로 내린다")] public Renderer rainStreaks;
    [Tooltip("비가 가장 셀 때 안개 짙기 (Exponential Squared)")] public float rainFogDensity = 0.045f;
    public Color rainFogColor = new Color(0.55f, 0.6f, 0.66f);
    [Tooltip("비가 가장 셀 때 해의 밝기 배율")] [Range(0f, 1f)] public float rainLightScale = 0.45f;
    [Header("눈")]
    [Tooltip("눈이 가장 셀 때 안개 짙기")] public float snowFogDensity = 0.025f;
    public Color snowFogColor = new Color(0.8f, 0.84f, 0.9f);
    [Tooltip("눈이 가장 셀 때 해의 밝기 배율")] [Range(0f, 1f)] public float snowLightScale = 0.75f;

    [Tooltip("조절할 해 (비우면 씬의 Directional Light 를 찾는다)")] public Light sun;

    readonly List<Renderer> _targets = new List<Renderer>();
    MaterialPropertyBlock _block;
    float _current;
    float _velocity;

    // 끌 때 되돌릴 원래 값
    bool _savedFog;
    FogMode _savedFogMode;
    float _savedFogDensity;
    Color _savedFogColor;
    float _savedSunIntensity;
    bool _saved;

    void Start()
    {
        FindTargets();
        if (slider != null)
        {
            slider.minValue = -1f;
            slider.maxValue = 1f;
            _current = slider.value;
        }
    }

    void FindTargets()
    {
        _block ??= new MaterialPropertyBlock();
        _targets.Clear();
        foreach (var r in FindObjectsByType<Renderer>(FindObjectsSortMode.None))
        {
            var mat = r.sharedMaterial;
            if (mat != null && mat.shader != null && mat.shader.name == "ShaderGallery/Mix/SeasonFoliage")
                _targets.Add(r);
        }
        if (sun == null)
        {
            foreach (var l in FindObjectsByType<Light>(FindObjectsSortMode.None))
                if (l.type == LightType.Directional) { sun = l; break; }
        }
        SaveEnvironment();
    }

    void SaveEnvironment()
    {
        if (_saved) return;
        _savedFog = RenderSettings.fog;
        _savedFogMode = RenderSettings.fogMode;
        _savedFogDensity = RenderSettings.fogDensity;
        _savedFogColor = RenderSettings.fogColor;
        _savedSunIntensity = sun != null ? sun.intensity : 1f;
        _saved = true;
    }

    void OnDisable()
    {
        if (!_saved) return;
        RenderSettings.fog = _savedFog;
        RenderSettings.fogMode = _savedFogMode;
        RenderSettings.fogDensity = _savedFogDensity;
        RenderSettings.fogColor = _savedFogColor;
        if (sun != null) sun.intensity = _savedSunIntensity;
    }

    void Update()
    {
        float target = slider != null ? slider.value : 0f;
        _current = smoothTime > 0f ? Mathf.SmoothDamp(_current, target, ref _velocity, smoothTime) : target;

        float gust = 0f;
        if (autoGust && gustInterval > 0f)
        {
            float g = Mathf.Repeat(Time.time, gustInterval);
            gust = g < 1.5f ? Mathf.Sin(g / 1.5f * Mathf.PI) : 0f;
        }

        Apply(_current, gust);

        if (label != null)
        {
            int percent = Mathf.RoundToInt(Mathf.Abs(target) * 100f);
            if (target < -0.01f) label.text = "비  " + percent + "%";
            else if (target > 0.01f) label.text = "눈  " + percent + "%";
            else label.text = "맑음";
        }
    }

    /// <summary>날씨 값(-1 비 ~ 0 맑음 ~ 1 눈)을 씬에 넣는다. 에디터 미리보기에서도 부른다.</summary>
    public void Apply(float weather, float gust = 0f)
    {
        if (_block == null) FindTargets();

        // 음수 쪽은 젖음, 양수 쪽은 눈. 0 에서 덮는 양이 0 이라 모드가 바뀌어도 티가 나지 않는다.
        float coverage = Mathf.Abs(weather) * maxCoverage;
        float mode = weather >= 0f ? 1f : 0f;
        float rain = Mathf.Clamp01(-weather);
        float snow = Mathf.Clamp01(weather);
        float fall = rain + snow;   // 둘 중 하나만 0 보다 크다

        foreach (var r in _targets)
        {
            if (r == null) continue;
            r.GetPropertyBlock(_block);
            _block.SetFloat(ModeId, mode);
            _block.SetFloat(CoverageId, coverage);
            _block.SetFloat(GustId, gust);
            _block.SetFloat(RainRippleId, rain);
            r.SetPropertyBlock(_block);
        }

        if (rainStreaks != null)
        {
            rainStreaks.enabled = fall > 0.001f;
            rainStreaks.GetPropertyBlock(_block);
            _block.SetFloat(RainAmountId, fall);
            _block.SetFloat(SnowModeId, mode);
            rainStreaks.SetPropertyBlock(_block);
        }

        // 흐린 날: 비나 눈이 셀수록 안개가 끼고 해가 어두워진다. 눈은 밝은 안개에 덜 어둡다.
        RenderSettings.fog = fall > 0.001f || _savedFog;
        if (fall > 0.001f)
        {
            RenderSettings.fogMode = FogMode.ExponentialSquared;
            RenderSettings.fogColor = mode > 0.5f ? snowFogColor : rainFogColor;
            float density = mode > 0.5f ? snowFogDensity : rainFogDensity;
            RenderSettings.fogDensity = Mathf.Lerp(_savedFog ? _savedFogDensity : 0f, density, fall);
        }
        else if (_savedFog)
        {
            RenderSettings.fogMode = _savedFogMode;
            RenderSettings.fogColor = _savedFogColor;
            RenderSettings.fogDensity = _savedFogDensity;
        }
        if (sun != null)
            sun.intensity = _savedSunIntensity * Mathf.Lerp(1f, mode > 0.5f ? snowLightScale : rainLightScale, fall);
    }
}

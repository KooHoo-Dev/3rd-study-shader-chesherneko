using UnityEngine;

/// <summary>
/// [믹스 3] 불타며 사라지기 데모용. 임계값(_Threshold)을 0 → 1 로 올려 태우고, 잠시 쉬었다가 다시 되살린다.
/// MaterialPropertyBlock 으로 값을 넣어 몸체와 불꽃 껍데기 두 머티리얼에 같은 값이 들어가고, 에셋은 바뀌지 않는다.
/// </summary>
[RequireComponent(typeof(Renderer))]
public class BurnLoop : MonoBehaviour
{
    static readonly int ThresholdId = Shader.PropertyToID("_Threshold");

    [Tooltip("다 타는 데 걸리는 시간(초)")]
    public float burnDuration = 3.5f;
    [Tooltip("다 탄 뒤, 되살아난 뒤 쉬는 시간(초)")]
    public float holdDuration = 1.2f;
    [Tooltip("여러 물체가 같은 박자로 타지 않게 시작 시간을 미룬다")]
    public float timeOffset;

    Renderer _renderer;
    MaterialPropertyBlock _block;

    void Awake()
    {
        _renderer = GetComponent<Renderer>();
        _block = new MaterialPropertyBlock();
    }

    void Update()
    {
        // 한 주기 = 쉬기 → 타기 → 쉬기 → 되살리기
        float cycle = (burnDuration + holdDuration) * 2f;
        float t = Mathf.Repeat(Time.time + timeOffset, cycle);
        float threshold;
        if (t < holdDuration) threshold = 0f;
        else if (t < holdDuration + burnDuration) threshold = (t - holdDuration) / burnDuration;
        else if (t < holdDuration * 2f + burnDuration) threshold = 1f;
        else threshold = 1f - (t - holdDuration * 2f - burnDuration) / burnDuration;

        _renderer.GetPropertyBlock(_block);
        _block.SetFloat(ThresholdId, Mathf.SmoothStep(0f, 1f, threshold));
        _renderer.SetPropertyBlock(_block);
    }
}

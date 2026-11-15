using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;

/// <summary>
/// 믹스 셰이더 확인용: 셰이더 컴파일 메시지를 콘솔에 찍고, 데모 씬 4개의 카메라 화면을 PNG 로 저장한다.
/// 메뉴: Tools > Mix Shaders > Capture Previews  (저장 위치: 프로젝트의 Temp/MixPreviews)
/// </summary>
[InitializeOnLoad]
public static class MixShaderPreview
{
    // 이 파일이 있으면 다음 컴파일 뒤 한 번 자동 실행하고 지운다. 내용은 저장할 폴더 경로다.
    const string RequestPath = "Library/MixShaderPreview.request";

    static MixShaderPreview()
    {
        if (File.Exists(RequestPath))
            EditorApplication.delayCall += AutoRun;
    }

    static void AutoRun()
    {
        if (EditorApplication.isPlayingOrWillChangePlaymode || EditorApplication.isCompiling || EditorApplication.isUpdating)
        {
            EditorApplication.delayCall += AutoRun;
            return;
        }
        string outDir = File.ReadAllText(RequestPath).Trim();
        File.Delete(RequestPath);
        Run(string.IsNullOrEmpty(outDir) ? "Temp/MixPreviews" : outDir);
    }

    [MenuItem("Tools/Mix Shaders/Capture Previews")]
    static void Menu()
    {
        if (!EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo()) return;
        Run("Temp/MixPreviews");
        EditorUtility.RevealInFinder("Temp/MixPreviews");
    }

    static void Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        bool asyncWas = ShaderUtil.allowAsyncCompilation;
        ShaderUtil.allowAsyncCompilation = false;
        var setup = EditorSceneManager.GetSceneManagerSetup();
        try
        {
            foreach (var path in new[] { MixShaderSetup.SceneToonWater, MixShaderSetup.SceneBurn, MixShaderSetup.SceneSeason, MixShaderSetup.SceneLava })
            {
                EditorSceneManager.OpenScene(path, OpenSceneMode.Single);
                var cam = Object.FindFirstObjectByType<Camera>();
                var rt = new RenderTexture(1280, 720, 24, RenderTextureFormat.ARGB32);
                cam.targetTexture = rt;
                // 화면 오버레이 UI 는 카메라 렌더에 안 들어가므로 캡처하는 동안만 카메라 공간 UI 로 바꾼다 (씬은 저장하지 않는다).
                foreach (var canvas in Object.FindObjectsByType<Canvas>(FindObjectsSortMode.None))
                {
                    if (canvas.renderMode != RenderMode.ScreenSpaceOverlay) continue;
                    canvas.renderMode = RenderMode.ScreenSpaceCamera;
                    canvas.worldCamera = cam;
                    canvas.planeDistance = cam.nearClipPlane + 0.1f;
                }
                Canvas.ForceUpdateCanvases();
                // 계절 숲은 비 쪽 날씨(비 85%)로 바꿔 찍는다. 빗방울, 파문, 안개는 플레이 중 비 쪽일 때만 보이기 때문이다. 씬은 저장하지 않는다.
                var weather = Object.FindFirstObjectByType<SeasonWeatherControl>();
                if (weather != null)
                {
                    weather.Apply(-0.85f);
                    if (weather.label != null) weather.label.text = "비  85%";
                    if (weather.slider != null) weather.slider.SetValueWithoutNotify(-0.85f);
                }
                // 첫 프레임은 그림자, 깊이 텍스처 준비로 비어 있을 수 있어 두 번 그린다.
                cam.Render();
                cam.Render();
                RenderTexture.active = rt;
                var tex = new Texture2D(rt.width, rt.height, TextureFormat.RGB24, false);
                tex.ReadPixels(new Rect(0, 0, rt.width, rt.height), 0, 0);
                tex.Apply();
                RenderTexture.active = null;
                cam.targetTexture = null;
                File.WriteAllBytes(Path.Combine(outDir, Path.GetFileNameWithoutExtension(path) + ".png"), tex.EncodeToPNG());
                Object.DestroyImmediate(tex);
                rt.Release();
                Object.DestroyImmediate(rt);
            }

            foreach (var name in new[] { "ToonWater", "BurningDissolve", "BurningDissolveFlame", "SeasonFoliage", "ToonFlowLava" })
            {
                var shader = Shader.Find("ShaderGallery/Mix/" + name);
                var messages = ShaderUtil.GetShaderMessages(shader);
                Debug.Log($"[MixShaderPreview] {name}: hasError={ShaderUtil.ShaderHasError(shader)}, messages={messages.Length}");
                foreach (var m in messages)
                    Debug.Log($"[MixShaderPreview]   {m.severity} {m.file}:{m.line} {m.message} ({m.platform})");
            }
            Debug.Log("[MixShaderPreview] 미리보기 저장: " + Path.GetFullPath(outDir));
        }
        catch (System.Exception e)
        {
            Debug.LogException(e);
        }
        finally
        {
            ShaderUtil.allowAsyncCompilation = asyncWas;
            if (setup != null && setup.Length > 0)
                EditorSceneManager.RestoreSceneManagerSetup(setup);
        }
    }
}




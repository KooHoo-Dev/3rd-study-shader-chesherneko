using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.SceneManagement;
using UnityEngine.EventSystems;
using UnityEngine.InputSystem.UI;
using UnityEngine.UI;

/// <summary>
/// 믹스 셰이더 4종에 필요한 텍스처, 메시, 머티리얼, 데모 씬을 한 번에 만든다.
/// 메뉴: Tools > Mix Shaders > Build All (자동 실행 후에도 언제든 다시 실행 가능)
/// 처음 컴파일될 때 한 번은 자동으로 실행된다 (열린 씬에 저장 안 한 변경이 있으면 건너뛴다).
/// 다시 실행해도 같은 결과가 나온다. 머티리얼은 GUID 를 유지한 채 값만 다시 넣는다.
/// </summary>
[InitializeOnLoad]
public static class MixShaderSetup
{
    const string ShaderDir = "Assets/Shaders";
    const string MaterialDir = "Assets/Materials";
    const string PropMaterialDir = "Assets/Materials/Props";
    const string TextureDir = "Assets/Textures";
    const string MeshDir = "Assets/Meshes";
    const string SceneDir = "Assets/Scenes";
    const string VolumeProfilePath = "Assets/Settings/SampleSceneProfile.asset";
    const string MarkerPath = "Library/MixShaderSetup_v1.done";

    public const string SceneToonWater = SceneDir + "/LampToon-Water.unity";
    public const string SceneBurn = SceneDir + "/Burn-Dissolve.unity";
    public const string SceneSeason = SceneDir + "/Season-Foliage.unity";
    public const string SceneLava = SceneDir + "/ToonFlow-Lava.unity";

    // 이 파일이 있으면 다음 컴파일 뒤 계절 숲 씬만 한 번 다시 만들고 지운다.
    const string SeasonRequestPath = "Library/MixShaderSetup.season.request";

    static MixShaderSetup()
    {
        if (!File.Exists(MarkerPath))
            EditorApplication.delayCall += AutoRun;
        else if (File.Exists(SeasonRequestPath))
            EditorApplication.delayCall += AutoRunSeason;
    }

    static void AutoRunSeason()
    {
        if (EditorApplication.isPlayingOrWillChangePlaymode || EditorApplication.isCompiling || EditorApplication.isUpdating)
        {
            EditorApplication.delayCall += AutoRunSeason;
            return;
        }
        for (int i = 0; i < SceneManager.sceneCount; i++)
        {
            if (SceneManager.GetSceneAt(i).isDirty)
            {
                Debug.LogWarning("[MixShaderSetup] 열린 씬에 저장하지 않은 변경이 있어 건너뜁니다. 저장 후 Tools > Mix Shaders > Rebuild Season Scene Only 를 실행하세요.");
                return;
            }
        }
        File.Delete(SeasonRequestPath);
        RebuildSeasonOnly();
    }

    static void AutoRun()
    {
        if (EditorApplication.isPlayingOrWillChangePlaymode || EditorApplication.isCompiling || EditorApplication.isUpdating)
        {
            EditorApplication.delayCall += AutoRun;
            return;
        }
        for (int i = 0; i < SceneManager.sceneCount; i++)
        {
            if (SceneManager.GetSceneAt(i).isDirty)
            {
                Debug.LogWarning("[MixShaderSetup] 열린 씬에 저장하지 않은 변경이 있어 자동 생성을 건너뜁니다. 저장 후 Tools > Mix Shaders > Build All 을 실행하세요.");
                return;
            }
        }
        if (BuildAll())
            File.WriteAllText(MarkerPath, System.DateTime.Now.ToString("s"));
    }

    [MenuItem("Tools/Mix Shaders/Build All")]
    static void BuildAllMenu()
    {
        if (!EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo()) return;
        if (BuildAll())
            File.WriteAllText(MarkerPath, System.DateTime.Now.ToString("s"));
    }

    static bool BuildAll()
    {
        var shaders = new Dictionary<string, Shader>();
        foreach (var name in new[] { "ToonWater", "BurningDissolve", "BurningDissolveFlame", "SeasonFoliage", "ToonFlowLava" })
        {
            var s = Shader.Find("ShaderGallery/Mix/" + name);
            if (s == null)
            {
                Debug.LogError("[MixShaderSetup] 셰이더를 찾지 못했습니다: ShaderGallery/Mix/" + name);
                return false;
            }
            shaders[name] = s;
        }

        var setup = EditorSceneManager.GetSceneManagerSetup();
        try
        {
            EnsureFolder(MaterialDir);
            EnsureFolder(PropMaterialDir);
            EnsureFolder(TextureDir);
            EnsureFolder(MeshDir);
            EnsureFolder(SceneDir);

            var tex = BuildTextures();
            var meshes = BuildMeshes();
            var mats = BuildMaterials(shaders, tex);
            AssetDatabase.SaveAssets();

            BuildSceneToonWater(mats, meshes);
            BuildSceneBurn(mats);
            BuildSceneSeason(mats, meshes);
            BuildSceneLava(mats);
            UpdateBuildSettings();
            Debug.Log("[MixShaderSetup] 완료: 텍스처, 메시, 머티리얼, 씬 4개를 만들었습니다.");
            return true;
        }
        catch (System.Exception e)
        {
            Debug.LogException(e);
            return false;
        }
        finally
        {
            if (setup != null && setup.Length > 0)
                EditorSceneManager.RestoreSceneManagerSetup(setup);
        }
    }

    // =====================================================================
    // 폴더
    // =====================================================================
    static void EnsureFolder(string path)
    {
        if (AssetDatabase.IsValidFolder(path)) return;
        string parent = Path.GetDirectoryName(path).Replace('\\', '/');
        EnsureFolder(parent);
        AssetDatabase.CreateFolder(parent, Path.GetFileName(path));
    }

    // =====================================================================
    // 텍스처 (반복되는 절차 텍스처를 PNG 로 굽는다)
    // =====================================================================
    class Textures
    {
        public Texture2D noiseValue, noiseFire, flow, lavaPattern, cobble, rock;
    }

    static Textures BuildTextures()
    {
        const int N = 256;
        var t = new Textures();

        // 고른 값 노이즈: 물결, 거품
        t.noiseValue = SaveTexture("Noise_Value", N, false, (u, v) =>
        {
            float n = Fbm(u, v, 8, 8, 4, 11);
            return new Color(n, n, n, 1);
        }, normalize: true);

        // 세로로 긴 결의 노이즈: 불꽃 (원본 노이즈 불꽃의 텍스처처럼 칸을 세로로 늘였다)
        t.noiseFire = SaveTexture("Noise_FireStreaks", N, false, (u, v) =>
        {
            float n = Fbm(u, v, 8, 3, 4, 23);
            return new Color(n, n, n, 1);
        }, normalize: true);

        // 플로 맵: 반복 노이즈의 회전(curl)으로 소용돌이 흐름을 만든다. RG = 흐름(0.5 멈춤), B = 위상 노이즈.
        {
            float[,] psi = new float[N, N];
            for (int y = 0; y < N; y++)
                for (int x = 0; x < N; x++)
                    psi[x, y] = Fbm((x + 0.5f) / N, (y + 0.5f) / N, 3, 3, 2, 37);
            float[,] fx = new float[N, N], fy = new float[N, N];
            float maxLen = 0.0001f;
            for (int y = 0; y < N; y++)
                for (int x = 0; x < N; x++)
                {
                    float dx = psi[(x + 1) % N, y] - psi[(x - 1 + N) % N, y];
                    float dy = psi[x, (y + 1) % N] - psi[x, (y - 1 + N) % N];
                    // 회전 흐름 (dψ/dy, -dψ/dx) 에 오른쪽 아래로 흐르는 바탕 흐름을 조금 더한다.
                    fx[x, y] = dy;
                    fy[x, y] = -dx;
                    maxLen = Mathf.Max(maxLen, Mathf.Sqrt(dx * dx + dy * dy));
                }
            var phase = NormalizedField(N, (u, v) => Fbm(u, v, 6, 6, 3, 53));
            t.flow = SaveTexture("Flow_Swirl", N, false, (u, v) =>
            {
                int x = Mathf.Min((int)(u * N), N - 1), y = Mathf.Min((int)(v * N), N - 1);
                float r = Mathf.Clamp01(0.5f + 0.5f * (fx[x, y] / maxLen * 0.8f + 0.2f));
                float g = Mathf.Clamp01(0.5f + 0.5f * (fy[x, y] / maxLen * 0.8f - 0.1f));
                return new Color(r, g, phase[x, y], 1);
            }, normalize: false);
        }

        // 용암 무늬: 보로노이 칸 사이 틈이 밝은 금, 칸 안은 식은 껍질
        t.lavaPattern = SaveTexture("Pattern_LavaCracks", N, false, (u, v) =>
        {
            Worley(u, v, 7, 71, out float f1, out float f2, out _);
            float crack = 1f - Mathf.SmoothStep(0f, 0.12f, f2 - f1);
            float detail = Fbm(u, v, 8, 8, 3, 79);
            float n = Mathf.Clamp01(crack * 0.8f + detail * 0.3f);
            return new Color(n, n, n, 1);
        }, normalize: true, gamma: 2.2f); // 대부분은 식은 껍질(어둡게), 금만 밝게

        // 돌길 (색, sRGB): 칸마다 다른 돌 색, 틈은 어둡게
        t.cobble = SaveTexture("Stone_Cobble", N, true, (u, v) =>
        {
            Worley(u, v, 6, 97, out float f1, out float f2, out int cell);
            float gap = Mathf.SmoothStep(0.02f, 0.08f, f2 - f1);
            float tone = 0.7f + 0.45f * Hash(cell, 3, 101);
            float detail = 0.85f + 0.3f * Fbm(u, v, 16, 16, 3, 103);
            var stone = new Color(0.46f, 0.43f, 0.39f) * tone * detail;
            var c = Color.Lerp(new Color(0.12f, 0.11f, 0.1f), stone, gap);
            c.a = 1;
            return c;
        }, normalize: false);

        // 바위 (색, sRGB): 결이 있는 회갈색
        t.rock = SaveTexture("Stone_Rock", N, true, (u, v) =>
        {
            float n = Fbm(u, v, 4, 4, 5, 113);
            float strata = 0.5f + 0.5f * Mathf.Sin((v * 4f + n * 1.5f) * Mathf.PI * 2f);
            float k = 0.55f + 0.35f * n + 0.12f * strata;
            var c = new Color(0.52f, 0.5f, 0.47f) * k;
            c.a = 1;
            return c;
        }, normalize: false);

        return t;
    }

    static float[,] NormalizedField(int n, System.Func<float, float, float> f)
    {
        var a = new float[n, n];
        float min = float.MaxValue, max = float.MinValue;
        for (int y = 0; y < n; y++)
            for (int x = 0; x < n; x++)
            {
                float v = f((x + 0.5f) / n, (y + 0.5f) / n);
                a[x, y] = v;
                min = Mathf.Min(min, v);
                max = Mathf.Max(max, v);
            }
        for (int y = 0; y < n; y++)
            for (int x = 0; x < n; x++)
                a[x, y] = (a[x, y] - min) / Mathf.Max(max - min, 0.0001f);
        return a;
    }

    static Texture2D SaveTexture(string name, int size, bool srgb, System.Func<float, float, Color> f, bool normalize, float gamma = 1f)
    {
        var pixels = new Color[size * size];
        float min = float.MaxValue, max = float.MinValue;
        for (int y = 0; y < size; y++)
            for (int x = 0; x < size; x++)
            {
                var c = f((x + 0.5f) / size, (y + 0.5f) / size);
                pixels[y * size + x] = c;
                min = Mathf.Min(min, c.r);
                max = Mathf.Max(max, c.r);
            }
        if (normalize)
        {
            float range = Mathf.Max(max - min, 0.0001f);
            for (int i = 0; i < pixels.Length; i++)
            {
                float v = Mathf.Pow((pixels[i].r - min) / range, gamma);
                pixels[i] = new Color(v, v, v, 1);
            }
        }

        var tex = new Texture2D(size, size, TextureFormat.RGBA32, false, !srgb);
        tex.SetPixels(pixels);
        tex.Apply();
        string path = TextureDir + "/" + name + ".png";
        File.WriteAllBytes(path, tex.EncodeToPNG());
        Object.DestroyImmediate(tex);

        AssetDatabase.ImportAsset(path, ImportAssetOptions.ForceUpdate);
        var importer = (TextureImporter)AssetImporter.GetAtPath(path);
        importer.textureType = TextureImporterType.Default;
        // 데이터 텍스처(노이즈, 플로 맵)는 sRGB 를 꺼야 0.5 가 그대로 0.5 로 읽힌다.
        importer.sRGBTexture = srgb;
        importer.wrapMode = TextureWrapMode.Repeat;
        importer.filterMode = FilterMode.Bilinear;
        importer.mipmapEnabled = true;
        importer.textureCompression = srgb ? TextureImporterCompression.Compressed : TextureImporterCompression.Uncompressed;
        importer.SaveAndReimport();
        return AssetDatabase.LoadAssetAtPath<Texture2D>(path);
    }

    // 반복되는 정수 해시 (0~1)
    static float Hash(int x, int y, int seed)
    {
        unchecked
        {
            uint h = (uint)(x * 374761393) ^ (uint)(y * 668265263) ^ (uint)(seed * 1442695041);
            h = (h ^ (h >> 13)) * 1274126177u;
            h ^= h >> 16;
            return (h & 0xFFFFFF) / 16777215f;
        }
    }

    static int Wrap(int a, int p) => ((a % p) + p) % p;

    // 주기 (px, py) 로 반복되는 값 노이즈
    static float PeriodicValue(float x, float y, int px, int py, int seed)
    {
        int x0 = Mathf.FloorToInt(x), y0 = Mathf.FloorToInt(y);
        float fx = x - x0, fy = y - y0;
        fx = fx * fx * (3 - 2 * fx);
        fy = fy * fy * (3 - 2 * fy);
        float a = Hash(Wrap(x0, px), Wrap(y0, py), seed);
        float b = Hash(Wrap(x0 + 1, px), Wrap(y0, py), seed);
        float c = Hash(Wrap(x0, px), Wrap(y0 + 1, py), seed);
        float d = Hash(Wrap(x0 + 1, px), Wrap(y0 + 1, py), seed);
        return Mathf.Lerp(Mathf.Lerp(a, b, fx), Mathf.Lerp(c, d, fx), fy);
    }

    // u, v (0~1) 에서 반복되는 프랙탈 노이즈
    static float Fbm(float u, float v, int px, int py, int octaves, int seed)
    {
        float sum = 0, amp = 0.5f, norm = 0;
        int f = 1;
        for (int o = 0; o < octaves; o++)
        {
            sum += PeriodicValue(u * px * f, v * py * f, px * f, py * f, seed + o * 17) * amp;
            norm += amp;
            amp *= 0.5f;
            f *= 2;
        }
        return sum / norm;
    }

    // 반복되는 보로노이: 가장 가까운 점 거리 f1, 두 번째 f2 (칸 단위)
    static void Worley(float u, float v, int cells, int seed, out float f1, out float f2, out int cellId)
    {
        float x = u * cells, y = v * cells;
        int cx = Mathf.FloorToInt(x), cy = Mathf.FloorToInt(y);
        f1 = 10; f2 = 10; cellId = 0;
        for (int j = -1; j <= 1; j++)
            for (int i = -1; i <= 1; i++)
            {
                int gx = cx + i, gy = cy + j;
                int wx = Wrap(gx, cells), wy = Wrap(gy, cells);
                float px = gx + 0.15f + 0.7f * Hash(wx, wy, seed);
                float py = gy + 0.15f + 0.7f * Hash(wx, wy, seed + 1);
                float d = Mathf.Sqrt((px - x) * (px - x) + (py - y) * (py - y));
                if (d < f1) { f2 = f1; f1 = d; cellId = wy * cells + wx; }
                else if (d < f2) f2 = d;
            }
    }

    // =====================================================================
    // 메시
    // =====================================================================
    class Meshes
    {
        public Mesh waterGrid, grassClump;
    }

    static Meshes BuildMeshes()
    {
        var m = new Meshes();
        m.waterGrid = SaveMesh("WaterGrid_10m", BuildGrid(10f, 100));
        m.grassClump = SaveMesh("GrassClump", BuildGrassClump(28, 0.42f, 5));
        return m;
    }

    static Mesh SaveMesh(string name, Mesh mesh)
    {
        string path = MeshDir + "/" + name + ".asset";
        var existing = AssetDatabase.LoadAssetAtPath<Mesh>(path);
        if (existing != null)
        {
            // GUID 를 유지한 채 내용만 바꾼다.
            existing.Clear();
            EditorUtility.CopySerialized(mesh, existing);
            existing.name = name;
            EditorUtility.SetDirty(existing);
            return existing;
        }
        mesh.name = name;
        AssetDatabase.CreateAsset(mesh, path);
        return mesh;
    }

    // 한 변 size m, cells x cells 칸의 평면. 물결이 정점 사이에서 깨지지 않게 촘촘하다 (원본 WaterSurfaceGrid 와 같은 규격).
    static Mesh BuildGrid(float size, int cells)
    {
        int n = cells + 1;
        var verts = new Vector3[n * n];
        var uvs = new Vector2[n * n];
        var normals = new Vector3[n * n];
        for (int j = 0; j < n; j++)
            for (int i = 0; i < n; i++)
            {
                int k = j * n + i;
                float u = (float)i / cells, v = (float)j / cells;
                verts[k] = new Vector3((u - 0.5f) * size, 0, (v - 0.5f) * size);
                uvs[k] = new Vector2(u, v);
                normals[k] = Vector3.up;
            }
        var tris = new int[cells * cells * 6];
        int t = 0;
        for (int j = 0; j < cells; j++)
            for (int i = 0; i < cells; i++)
            {
                int a = j * n + i, b = a + 1, c = a + n, d = c + 1;
                tris[t++] = a; tris[t++] = c; tris[t++] = b;
                tris[t++] = b; tris[t++] = c; tris[t++] = d;
            }
        var mesh = new Mesh();
        mesh.indexFormat = IndexFormat.UInt32;
        mesh.vertices = verts;
        mesh.uv = uvs;
        mesh.normals = normals;
        mesh.triangles = tris;
        mesh.RecalculateTangents();
        // 파도가 올라와도 잘리지 않게 위아래로 넉넉히 잡는다.
        mesh.bounds = new Bounds(Vector3.zero, new Vector3(size, 2f, size));
        return mesh;
    }

    // 풀 다발: 뿌리가 y = 0, uv.y 가 뿌리 0 → 끝 1 인 가는 잎 여러 장 (바람 흔들림 원본의 메시 규약)
    static Mesh BuildGrassClump(int blades, float radius, int segments)
    {
        var rnd = new System.Random(1234);
        var verts = new List<Vector3>();
        var uvs = new List<Vector2>();
        var tris = new List<int>();
        for (int b = 0; b < blades; b++)
        {
            float ang = (float)rnd.NextDouble() * Mathf.PI * 2f;
            float r = Mathf.Sqrt((float)rnd.NextDouble()) * radius;
            var root = new Vector3(Mathf.Cos(ang) * r, 0, Mathf.Sin(ang) * r);
            float yaw = (float)rnd.NextDouble() * Mathf.PI * 2f;
            var across = new Vector3(Mathf.Cos(yaw), 0, Mathf.Sin(yaw));
            var lean = new Vector3(-across.z, 0, across.x) * (0.1f + 0.25f * (float)rnd.NextDouble());
            // 바깥쪽으로 조금 벌어지게 한다.
            lean += new Vector3(root.x, 0, root.z) * 0.6f;
            float height = 0.45f + 0.45f * (float)rnd.NextDouble();
            float width = 0.05f + 0.03f * (float)rnd.NextDouble();
            int start = verts.Count;
            for (int s = 0; s <= segments; s++)
            {
                float k = (float)s / segments;
                var center = root + Vector3.up * (height * k) + lean * (k * k * height);
                float w = width * (1f - k * 0.92f) * 0.5f;
                verts.Add(center - across * w);
                verts.Add(center + across * w);
                uvs.Add(new Vector2(0, k));
                uvs.Add(new Vector2(1, k));
            }
            for (int s = 0; s < segments; s++)
            {
                int a = start + s * 2;
                tris.Add(a); tris.Add(a + 2); tris.Add(a + 1);
                tris.Add(a + 1); tris.Add(a + 2); tris.Add(a + 3);
            }
        }
        var mesh = new Mesh();
        mesh.SetVertices(verts);
        mesh.SetUVs(0, uvs);
        mesh.SetTriangles(tris, 0);
        mesh.RecalculateNormals();
        mesh.RecalculateBounds();
        var bounds = mesh.bounds;
        bounds.Expand(0.6f); // 바람에 밀려도 잘리지 않게
        mesh.bounds = bounds;
        return mesh;
    }

    // =====================================================================
    // 머티리얼
    // =====================================================================
    class Mats
    {
        public Material water, burnBody, burnFlame, burnBodyBlue, burnFlameBlue;
        public Material seasonGround, seasonRock, seasonGrass;
        public Material lavaPool, lavaBall;
        public Material propSand, propRock, propWood, propBasalt, propFloor;
    }

    static Material GetOrCreateMaterial(string path, Shader shader)
    {
        var mat = AssetDatabase.LoadAssetAtPath<Material>(path);
        if (mat == null)
        {
            mat = new Material(shader);
            AssetDatabase.CreateAsset(mat, path);
        }
        else
        {
            mat.shader = shader;
        }
        EditorUtility.SetDirty(mat);
        return mat;
    }

    static Mats BuildMaterials(Dictionary<string, Shader> s, Textures tex)
    {
        var m = new Mats();

        // ---- 1. 툰 바다
        m.water = GetOrCreateMaterial(MaterialDir + "/MixToonWater.mat", s["ToonWater"]);
        m.water.SetTexture("_NoiseTex", tex.noiseValue);
        m.water.SetFloat("_CrestFoam", 0.9f);

        // ---- 3. 불타며 사라지기 (몸체 + 불꽃 껍데기는 같은 값을 써야 한다)
        m.burnBody = GetOrCreateMaterial(MaterialDir + "/BurningDissolve_Body.mat", s["BurningDissolve"]);
        m.burnFlame = GetOrCreateMaterial(MaterialDir + "/BurningDissolve_Flame.mat", s["BurningDissolveFlame"]);
        foreach (var mat in new[] { m.burnBody, m.burnFlame })
        {
            mat.SetTexture("_NoiseTex", tex.noiseFire);
            mat.SetColor("_BaseColor", new Color(0.78f, 0.74f, 0.68f));
        }
        // 푸른 영혼불 변형
        m.burnBodyBlue = GetOrCreateMaterial(MaterialDir + "/BurningDissolve_Body_Blue.mat", s["BurningDissolve"]);
        m.burnFlameBlue = GetOrCreateMaterial(MaterialDir + "/BurningDissolve_Flame_Blue.mat", s["BurningDissolveFlame"]);
        foreach (var mat in new[] { m.burnBodyBlue, m.burnFlameBlue })
        {
            mat.SetTexture("_NoiseTex", tex.noiseFire);
            mat.SetColor("_BaseColor", new Color(0.35f, 0.38f, 0.5f));
            mat.SetColor("_CoreColor", new Color(0.85f, 1f, 1f));
            mat.SetColor("_MidColor", new Color(0.2f, 0.75f, 1f));
            mat.SetColor("_EdgeColor", new Color(0.25f, 0.15f, 0.9f));
            mat.SetColor("_CharColor", new Color(0.03f, 0.03f, 0.06f));
            mat.SetFloat("_Sweep", 0.6f);
            mat.SetFloat("_NoiseScale", 3f);
        }

        // ---- 5. 계절 숲 (셰이더 하나로 지면, 바위, 풀)
        m.seasonGround = GetOrCreateMaterial(MaterialDir + "/SeasonFoliage_Ground.mat", s["SeasonFoliage"]);
        m.seasonGround.SetTexture("_TileTex", tex.cobble);
        m.seasonGround.SetFloat("_TileSize", 1.6f);
        m.seasonGround.SetFloat("_Space", 0);
        m.seasonGround.SetFloat("_WindStrength", 0);
        m.seasonGround.SetFloat("_Flutter", 0);
        m.seasonGround.SetFloat("_NoiseScale", 1.5f);

        m.seasonRock = GetOrCreateMaterial(MaterialDir + "/SeasonFoliage_Rock.mat", s["SeasonFoliage"]);
        m.seasonRock.SetTexture("_TileTex", tex.rock);
        m.seasonRock.SetFloat("_TileSize", 0.9f);
        m.seasonRock.SetFloat("_Space", 1);
        m.seasonRock.SetFloat("_WindStrength", 0);
        m.seasonRock.SetFloat("_Flutter", 0);
        m.seasonRock.SetFloat("_NoiseScale", 3f);

        m.seasonGrass = GetOrCreateMaterial(MaterialDir + "/SeasonFoliage_Grass.mat", s["SeasonFoliage"]);
        m.seasonGrass.SetColor("_RootColor", new Color(0.09f, 0.22f, 0.07f));
        m.seasonGrass.SetColor("_TipColor", new Color(0.55f, 0.72f, 0.22f));
        m.seasonGrass.SetFloat("_TwoSidedLighting", 1);
        m.seasonGrass.SetFloat("_WindStrength", 0.28f);
        m.seasonGrass.SetFloat("_Flutter", 0.04f);
        m.seasonGrass.SetFloat("_TipCatch", 0.5f);
        m.seasonGrass.SetFloat("_NoiseScale", 6f);
        m.seasonGrass.SetFloat("_Cull", (float)CullMode.Off);
        // 풀은 삼평면 텍스처를 비워 셰이더 기본값(white)을 쓰고, 색은 뿌리→끝 그라데이션이 정한다.
        m.seasonGrass.SetTexture("_TileTex", null);

        SeasonDefaults(m.seasonGround, m.seasonRock, m.seasonGrass);

        // ---- 6. 툰 용암
        m.lavaPool = GetOrCreateMaterial(MaterialDir + "/ToonFlowLava_Pool.mat", s["ToonFlowLava"]);
        m.lavaBall = GetOrCreateMaterial(MaterialDir + "/ToonFlowLava_Ball.mat", s["ToonFlowLava"]);
        foreach (var mat in new[] { m.lavaPool, m.lavaBall })
        {
            mat.SetTexture("_FlowTex", tex.flow);
            mat.SetTexture("_PatternTex", tex.lavaPattern);
        }
        m.lavaPool.SetFloat("_PatternScale", 6f);
        m.lavaPool.SetFloat("_Glow", 1.6f);
        m.lavaBall.SetFloat("_Glow", 1.6f);
        m.lavaPool.SetFloat("_FlowStrength", 0.1f);
        m.lavaPool.SetFloat("_Speed", 0.2f);
        m.lavaBall.SetFloat("_PatternScale", 3f);
        m.lavaBall.SetFloat("_FlowStrength", 0.18f);

        // ---- 소품 (URP Lit)
        var lit = Shader.Find("Universal Render Pipeline/Lit");
        m.propSand = Prop("Prop_Sand", lit, new Color(0.86f, 0.78f, 0.55f));
        m.propRock = Prop("Prop_Rock", lit, new Color(0.45f, 0.45f, 0.48f));
        m.propWood = Prop("Prop_Wood", lit, new Color(0.55f, 0.36f, 0.2f));
        m.propBasalt = Prop("Prop_Basalt", lit, new Color(0.12f, 0.1f, 0.11f));
        m.propFloor = Prop("Prop_Floor", lit, new Color(0.22f, 0.22f, 0.24f));
        return m;
    }

    // 계절 숲 정지 화면(플레이 전)에서도 섞인 모습이 보이게 눈을 조금만 덮어 둔다. 플레이하면 슬라이더(SeasonWeatherControl)가 바꾼다.
    static void SeasonDefaults(params Material[] mats)
    {
        foreach (var mat in mats)
        {
            mat.SetFloat("_Mode", 1);
            mat.SetFloat("_Coverage", 0.3f);
        }
    }

    static Material Prop(string name, Shader lit, Color color)
    {
        var mat = GetOrCreateMaterial(PropMaterialDir + "/" + name + ".mat", lit);
        mat.SetColor("_BaseColor", color);
        mat.SetFloat("_Smoothness", 0.15f);
        return mat;
    }

    // =====================================================================
    // 씬
    // =====================================================================
    static Scene NewDemoScene(Vector3 camPos, Vector3 camEuler, Vector3 lightEuler)
    {
        var scene = EditorSceneManager.NewScene(NewSceneSetup.DefaultGameObjects, NewSceneMode.Single);
        var cam = Object.FindFirstObjectByType<Camera>();
        cam.transform.SetPositionAndRotation(camPos, Quaternion.Euler(camEuler));
        cam.GetUniversalAdditionalCameraData().renderPostProcessing = true;
        var light = Object.FindFirstObjectByType<Light>();
        light.transform.rotation = Quaternion.Euler(lightEuler);
        light.shadows = LightShadows.Soft;

        var volumeGo = new GameObject("Global Volume");
        var volume = volumeGo.AddComponent<Volume>();
        volume.isGlobal = true;
        volume.sharedProfile = AssetDatabase.LoadAssetAtPath<VolumeProfile>(VolumeProfilePath);
        return scene;
    }

    static GameObject Prim(PrimitiveType type, string name, Vector3 pos, Vector3 scale, Material mat, Vector3 euler = default, Transform parent = null)
    {
        var go = GameObject.CreatePrimitive(type);
        go.name = name;
        go.transform.SetParent(parent, false);
        go.transform.localPosition = pos;
        go.transform.localRotation = Quaternion.Euler(euler);
        go.transform.localScale = scale;
        go.GetComponent<Renderer>().sharedMaterial = mat;
        return go;
    }

    static GameObject MeshObject(string name, Mesh mesh, Material mat, Vector3 pos, Vector3 euler, Vector3 scale, Transform parent = null)
    {
        var go = new GameObject(name);
        go.transform.SetParent(parent, false);
        go.transform.localPosition = pos;
        go.transform.localRotation = Quaternion.Euler(euler);
        go.transform.localScale = scale;
        go.AddComponent<MeshFilter>().sharedMesh = mesh;
        go.AddComponent<MeshRenderer>().sharedMaterial = mat;
        return go;
    }

    static void Save(Scene scene, string path)
    {
        EditorSceneManager.SaveScene(scene, path);
    }

    // ---- 1. 툰 바다: 물 위로 솟은 바위, 기둥, 상자, 모래섬 둘레에 거품이 생긴다.
    static void BuildSceneToonWater(Mats m, Meshes meshes)
    {
        var scene = NewDemoScene(new Vector3(0, 4.5f, -10f), new Vector3(22, 0, 0), new Vector3(35, 160, 0));
        var root = new GameObject("MixDemo_ToonWater").transform;
        MeshObject("ToonWater", meshes.waterGrid, m.water, Vector3.zero, Vector3.zero, new Vector3(1.6f, 1, 1.6f), root);
        Prim(PrimitiveType.Plane, "Seabed", new Vector3(0, -1.2f, 0), new Vector3(2, 1, 2), m.propSand, default, root);
        Prim(PrimitiveType.Sphere, "SandIsland", new Vector3(-3.8f, -0.8f, 3.2f), new Vector3(5, 2.2f, 4), m.propSand, default, root);
        Prim(PrimitiveType.Sphere, "Rock_A", new Vector3(2.2f, -0.2f, 1.2f), new Vector3(1.3f, 1.7f, 1.1f), m.propRock, new Vector3(0, 30, 10), root);
        Prim(PrimitiveType.Sphere, "Rock_B", new Vector3(3.4f, -0.5f, -1.6f), new Vector3(1.0f, 1.2f, 0.9f), m.propRock, new Vector3(0, -20, -8), root);
        Prim(PrimitiveType.Sphere, "Rock_C", new Vector3(-1.6f, -0.6f, -2.8f), new Vector3(0.8f, 1.0f, 0.9f), m.propRock, default, root);
        Prim(PrimitiveType.Cylinder, "Pillar", new Vector3(-0.6f, 0.2f, 0.6f), new Vector3(0.45f, 1.4f, 0.45f), m.propWood, default, root);
        Prim(PrimitiveType.Cube, "Crate", new Vector3(0.9f, -0.05f, -1.4f), new Vector3(0.8f, 0.8f, 0.8f), m.propWood, new Vector3(8, 35, 5), root);
        Save(scene, SceneToonWater);
    }

    // ---- 3. 불타며 사라지기: 셋이 시간차를 두고 타고, 되살아난다.
    static void BuildSceneBurn(Mats m)
    {
        var scene = NewDemoScene(new Vector3(0, 2.3f, -6.5f), new Vector3(12, 0, 0), new Vector3(50, -30, 0));
        var root = new GameObject("MixDemo_BurningDissolve").transform;
        Prim(PrimitiveType.Plane, "Floor", Vector3.zero, new Vector3(2, 1, 2), m.propFloor, default, root);

        var sphere = Prim(PrimitiveType.Sphere, "Burn_Sphere", new Vector3(-2.3f, 0.9f, 0), Vector3.one * 1.6f, m.burnBody, default, root);
        var capsule = Prim(PrimitiveType.Capsule, "Burn_Capsule_Blue", new Vector3(0, 1.05f, 0.4f), new Vector3(1f, 1f, 1f), m.burnBodyBlue, default, root);
        var cube = Prim(PrimitiveType.Cube, "Burn_Cube", new Vector3(2.3f, 0.75f, 0), Vector3.one * 1.3f, m.burnBody, new Vector3(0, 35, 0), root);

        sphere.GetComponent<Renderer>().sharedMaterials = new[] { m.burnBody, m.burnFlame };
        capsule.GetComponent<Renderer>().sharedMaterials = new[] { m.burnBodyBlue, m.burnFlameBlue };
        cube.GetComponent<Renderer>().sharedMaterials = new[] { m.burnBody, m.burnFlame };

        sphere.AddComponent<BurnLoop>().timeOffset = 0f;
        capsule.AddComponent<BurnLoop>().timeOffset = 1.6f;
        cube.AddComponent<BurnLoop>().timeOffset = 3.2f;
        Save(scene, SceneBurn);
    }

    // ---- 5. 계절 숲: 돌길 지면, 바위, 풀 다발. 화면 아래 슬라이더로 비 ~ 맑음 ~ 눈 을 직접 조절한다.
    static void BuildSceneSeason(Mats m, Meshes meshes)
    {
        var scene = NewDemoScene(new Vector3(0, 3.2f, -8f), new Vector3(20, 0, 0), new Vector3(45, -35, 0));
        var root = new GameObject("MixDemo_SeasonFoliage").transform;
        Prim(PrimitiveType.Cube, "Ground", new Vector3(0, -0.2f, 0), new Vector3(14, 0.4f, 14), m.seasonGround, default, root);

        var rocks = new[]
        {
            (new Vector3(-2.6f, 0.3f, 1.5f), new Vector3(1.8f, 1.1f, 1.4f), new Vector3(0, 20, 8), PrimitiveType.Sphere),
            (new Vector3(2.4f, 0.4f, 2.4f), new Vector3(1.4f, 1.4f, 1.4f), new Vector3(15, 40, 10), PrimitiveType.Cube),
            (new Vector3(0.6f, 0.15f, -0.6f), new Vector3(0.9f, 0.6f, 0.8f), new Vector3(0, -30, 0), PrimitiveType.Sphere),
            (new Vector3(-0.8f, 0.6f, 4.2f), new Vector3(2.2f, 1.8f, 1.6f), new Vector3(0, 10, -5), PrimitiveType.Sphere),
            (new Vector3(3.8f, 0.2f, -1.2f), new Vector3(0.8f, 0.8f, 0.8f), new Vector3(30, 10, 20), PrimitiveType.Cube),
        };
        int i = 0;
        foreach (var (pos, scale, euler, type) in rocks)
            Prim(type, "Rock_" + (i++), pos, scale, m.seasonRock, euler, root);

        var grass = new GameObject("Grass").transform;
        grass.SetParent(root, false);
        var rnd = new System.Random(42);
        int placed = 0;
        for (int tries = 0; tries < 400 && placed < 60; tries++)
        {
            var p = new Vector3(((float)rnd.NextDouble() - 0.5f) * 11f, 0, ((float)rnd.NextDouble() - 0.5f) * 9f + 0.5f);
            bool blocked = false;
            foreach (var (pos, scale, _, _) in rocks)
                if (new Vector2(p.x - pos.x, p.z - pos.z).magnitude < Mathf.Max(scale.x, scale.z) * 0.55f) blocked = true;
            if (blocked) continue;
            float s = 0.8f + 0.6f * (float)rnd.NextDouble();
            MeshObject("GrassClump_" + placed, meshes.grassClump, m.seasonGrass, p, new Vector3(0, (float)rnd.NextDouble() * 360f, 0), Vector3.one * s, grass);
            placed++;
        }

        var control = BuildWeatherUI();
        control.rainStreaks = BuildRainStreaks();
        Save(scene, SceneSeason);
    }

    // 3D 빗방울: 씬을 덮는 상자(가로 18 m, 세로 9 m) 안에 방울 수천 개를 흩뿌린 메시 하나.
    // 방울 하나 = 네 정점이 같은 위치를 가진 사각형. 떨어뜨리기와 카메라 쪽으로 세우기는 셰이더가 한다.
    const float RainBoxSize = 18f;
    const float RainBoxHeight = 9f;

    static Renderer BuildRainStreaks()
    {
        var shader = Shader.Find("ShaderGallery/Mix/RainStreaks");
        if (shader == null)
        {
            Debug.LogError("[MixShaderSetup] 셰이더를 찾지 못했습니다: ShaderGallery/Mix/RainStreaks");
            return null;
        }
        var mat = GetOrCreateMaterial(MaterialDir + "/RainStreaks.mat", shader);
        mat.SetFloat("_BoxHeight", RainBoxHeight);
        var mesh = SaveMesh("RainDrops", BuildRainDropMesh(7000, RainBoxSize, RainBoxHeight));
        AssetDatabase.SaveAssets();

        var go = new GameObject("Rain (RainStreaks)");
        go.transform.position = new Vector3(0, 0, 2f);
        go.AddComponent<MeshFilter>().sharedMesh = mesh;
        var r = go.AddComponent<MeshRenderer>();
        r.sharedMaterial = mat;
        r.shadowCastingMode = ShadowCastingMode.Off;
        r.receiveShadows = false;
        // 에디터에서는 꺼 둔다. 플레이하면 스크립트가 비나 눈이 올 때 켜고 모드를 넣는다.
        r.enabled = false;
        return r;
    }

    static Mesh BuildRainDropMesh(int count, float size, float height)
    {
        var rnd = new System.Random(2024);
        var verts = new Vector3[count * 4];
        var corners = new Vector2[count * 4];
        var randoms = new Vector2[count * 4];
        var tris = new int[count * 6];
        var cornerTable = new[] { new Vector2(-1, 0), new Vector2(1, 0), new Vector2(-1, 1), new Vector2(1, 1) };
        for (int i = 0; i < count; i++)
        {
            var pos = new Vector3(((float)rnd.NextDouble() - 0.5f) * size, (float)rnd.NextDouble() * height, ((float)rnd.NextDouble() - 0.5f) * size);
            // 첫 난수는 '비의 양' 비교에 쓴다. 고르게 퍼져 있어야 비의 양에 비례해 방울 수가 는다.
            var random = new Vector2((float)rnd.NextDouble(), (float)rnd.NextDouble());
            for (int k = 0; k < 4; k++)
            {
                verts[i * 4 + k] = pos;
                corners[i * 4 + k] = cornerTable[k];
                randoms[i * 4 + k] = random;
            }
            int v = i * 4, t = i * 6;
            tris[t] = v; tris[t + 1] = v + 2; tris[t + 2] = v + 1;
            tris[t + 3] = v + 1; tris[t + 4] = v + 2; tris[t + 5] = v + 3;
        }
        var mesh = new Mesh();
        mesh.indexFormat = IndexFormat.UInt32;
        mesh.vertices = verts;
        mesh.uv = corners;
        mesh.uv2 = randoms;
        mesh.triangles = tris;
        // 셰이더가 정점을 옮기므로 경계 상자를 넉넉히 잡아 화면 밖으로 잘못 잘리지 않게 한다.
        mesh.bounds = new Bounds(new Vector3(0, height * 0.5f, 0), new Vector3(size + 4f, height + 2f, size + 4f));
        return mesh;
    }

    // 화면 아래 가운데에 날씨 슬라이더 하나: 왼쪽 비 ~ 가운데 맑음 ~ 오른쪽 눈
    static SeasonWeatherControl BuildWeatherUI()
    {
        var res = new DefaultControls.Resources
        {
            standard = AssetDatabase.GetBuiltinExtraResource<Sprite>("UI/Skin/UISprite.psd"),
            background = AssetDatabase.GetBuiltinExtraResource<Sprite>("UI/Skin/Background.psd"),
            knob = AssetDatabase.GetBuiltinExtraResource<Sprite>("UI/Skin/Knob.psd"),
        };
        var font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");

        var canvasGo = new GameObject("WeatherUI", typeof(Canvas), typeof(CanvasScaler), typeof(GraphicRaycaster));
        canvasGo.GetComponent<Canvas>().renderMode = RenderMode.ScreenSpaceOverlay;
        var scaler = canvasGo.GetComponent<CanvasScaler>();
        scaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize;
        scaler.referenceResolution = new Vector2(1920, 1080);
        scaler.matchWidthOrHeight = 0.5f;

        // 반투명 판
        var panel = new GameObject("Panel", typeof(RectTransform), typeof(Image));
        panel.transform.SetParent(canvasGo.transform, false);
        var panelRt = (RectTransform)panel.transform;
        panelRt.anchorMin = panelRt.anchorMax = new Vector2(0.5f, 0f);
        panelRt.pivot = new Vector2(0.5f, 0f);
        panelRt.anchoredPosition = new Vector2(0, 40);
        panelRt.sizeDelta = new Vector2(820, 150);
        var panelImage = panel.GetComponent<Image>();
        panelImage.sprite = res.background;
        panelImage.type = Image.Type.Sliced;
        panelImage.color = new Color(0f, 0f, 0f, 0.45f);

        // 슬라이더 (-1 ~ 1). 채우기 막대는 가운데에서 시작하는 값과 맞지 않아 끈다.
        var sliderGo = DefaultControls.CreateSlider(res);
        sliderGo.name = "WeatherSlider";
        sliderGo.transform.SetParent(panel.transform, false);
        var sliderRt = (RectTransform)sliderGo.transform;
        sliderRt.anchorMin = sliderRt.anchorMax = new Vector2(0.5f, 0f);
        sliderRt.pivot = new Vector2(0.5f, 0.5f);
        sliderRt.anchoredPosition = new Vector2(0, 45);
        sliderRt.sizeDelta = new Vector2(600, 28);
        var slider = sliderGo.GetComponent<Slider>();
        slider.transform.Find("Fill Area").gameObject.SetActive(false);
        slider.fillRect = null;
        slider.minValue = -1f;
        slider.maxValue = 1f;
        // 머티리얼에 저장된 정지 화면 값(눈, 덮는 양 0.3)과 맞춘 시작값. 0.35 x 최대 0.85 ≈ 0.3
        slider.value = 0.35f;
        ((RectTransform)slider.handleRect).sizeDelta = new Vector2(36, 0);

        Text MakeText(string name, string text, Vector2 pos, Vector2 size, int fontSize, TextAnchor align)
        {
            var go = new GameObject(name, typeof(RectTransform), typeof(Text), typeof(Shadow));
            go.transform.SetParent(panel.transform, false);
            var rt = (RectTransform)go.transform;
            rt.anchorMin = rt.anchorMax = new Vector2(0.5f, 0f);
            rt.pivot = new Vector2(0.5f, 0.5f);
            rt.anchoredPosition = pos;
            rt.sizeDelta = size;
            var t = go.GetComponent<Text>();
            t.font = font;
            t.text = text;
            t.fontSize = fontSize;
            t.alignment = align;
            t.color = Color.white;
            return t;
        }

        var label = MakeText("WeatherLabel", "눈  35%", new Vector2(0, 112), new Vector2(400, 50), 36, TextAnchor.MiddleCenter);
        MakeText("Left", "비", new Vector2(-355, 45), new Vector2(80, 40), 26, TextAnchor.MiddleCenter);
        MakeText("Right", "눈", new Vector2(355, 45), new Vector2(80, 40), 26, TextAnchor.MiddleCenter);
        MakeText("Center", "맑음", new Vector2(0, 12), new Vector2(120, 30), 20, TextAnchor.MiddleCenter);

        // 이 프로젝트는 Input System 전용이라 UI 입력 모듈도 Input System 용을 쓴다.
        new GameObject("EventSystem", typeof(EventSystem), typeof(InputSystemUIInputModule));

        var control = new GameObject("Weather (SeasonWeatherControl)").AddComponent<SeasonWeatherControl>();
        control.slider = slider;
        control.label = label;
        return control;
    }

    [MenuItem("Tools/Mix Shaders/Rebuild Season Scene Only")]
    static void RebuildSeasonMenu()
    {
        if (!EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo()) return;
        RebuildSeasonOnly();
    }

    // 계절 숲 씬만 다시 만든다. 이미 만들어 둔 머티리얼과 메시를 그대로 쓰고 다른 씬은 건드리지 않는다.
    static bool RebuildSeasonOnly()
    {
        var m = new Mats
        {
            seasonGround = AssetDatabase.LoadAssetAtPath<Material>(MaterialDir + "/SeasonFoliage_Ground.mat"),
            seasonRock = AssetDatabase.LoadAssetAtPath<Material>(MaterialDir + "/SeasonFoliage_Rock.mat"),
            seasonGrass = AssetDatabase.LoadAssetAtPath<Material>(MaterialDir + "/SeasonFoliage_Grass.mat"),
        };
        var meshes = new Meshes { grassClump = AssetDatabase.LoadAssetAtPath<Mesh>(MeshDir + "/GrassClump.asset") };
        if (m.seasonGround == null || m.seasonRock == null || m.seasonGrass == null || meshes.grassClump == null)
        {
            Debug.LogError("[MixShaderSetup] 계절 숲 머티리얼이나 메시가 없습니다. Build All 을 먼저 실행하세요.");
            return false;
        }
        var setup = EditorSceneManager.GetSceneManagerSetup();
        try
        {
            BuildSceneSeason(m, meshes);
            Debug.Log("[MixShaderSetup] 계절 숲 씬만 다시 만들었습니다.");
            return true;
        }
        catch (System.Exception e)
        {
            Debug.LogException(e);
            return false;
        }
        finally
        {
            if (setup != null && setup.Length > 0)
                EditorSceneManager.RestoreSceneManagerSetup(setup);
        }
    }

    // ---- 6. 툰 용암: 용암 웅덩이와 떠 있는 용암 구슬, 주변 현무암
    static void BuildSceneLava(Mats m)
    {
        var scene = NewDemoScene(new Vector3(0, 3.6f, -8f), new Vector3(22, 0, 0), new Vector3(50, -30, 0));
        var root = new GameObject("MixDemo_ToonFlowLava").transform;
        Prim(PrimitiveType.Plane, "LavaPool", Vector3.zero, new Vector3(1.2f, 1, 1.2f), m.lavaPool, default, root);
        Prim(PrimitiveType.Sphere, "LavaBall", new Vector3(0, 1.5f, 0.5f), Vector3.one * 2.2f, m.lavaBall, default, root);
        Prim(PrimitiveType.Sphere, "LavaBall_Small", new Vector3(-2.6f, 0.7f, -0.5f), Vector3.one * 1.1f, m.lavaBall, new Vector3(0, 90, 0), root);
        Prim(PrimitiveType.Cube, "Basalt_A", new Vector3(2.8f, 0.3f, -0.8f), new Vector3(1.4f, 1.2f, 1.2f), m.propBasalt, new Vector3(10, 25, 5), root);
        Prim(PrimitiveType.Sphere, "Basalt_B", new Vector3(-3.4f, 0.1f, 2.6f), new Vector3(2.2f, 1.2f, 1.8f), m.propBasalt, default, root);
        Prim(PrimitiveType.Cube, "Basalt_C", new Vector3(3.6f, 0.4f, 3.2f), new Vector3(1.6f, 2.0f, 1.4f), m.propBasalt, new Vector3(0, -15, 8), root);
        Save(scene, SceneLava);
    }

    static void UpdateBuildSettings()
    {
        var list = new List<EditorBuildSettingsScene>();
        var wanted = new[] { SceneToonWater, SceneBurn, SceneSeason, SceneLava };
        foreach (var path in wanted)
            list.Add(new EditorBuildSettingsScene(path, true));
        foreach (var existing in EditorBuildSettings.scenes)
            if (System.Array.IndexOf(wanted, existing.path) < 0)
                list.Add(existing);
        EditorBuildSettings.scenes = list.ToArray();
    }
}

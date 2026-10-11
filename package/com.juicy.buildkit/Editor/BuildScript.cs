using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build.Reporting;

namespace JuicyBuildKit
{
    /// <summary>
    /// Batch-mode entry point:
    /// Unity -batchmode -nographics -quit -projectPath . -buildTarget Android -executeMethod JuicyBuildKit.BuildScript.BuildAab
    /// Signing and options come from environment variables (see env.template). No secrets live in this file.
    /// </summary>
    public static class BuildScript
    {
        public static void BuildAab()
        {
            try
            {
                EditorUserBuildSettings.buildAppBundle = true;

                ApplySigningFromEnvironment();

                if (Environment.GetEnvironmentVariable("UNITY_BUMP_VERSION_CODE") == "1")
                {
                    PlayerSettings.Android.bundleVersionCode++;
                    UnityEngine.Debug.Log("Bumped bundleVersionCode to " + PlayerSettings.Android.bundleVersionCode);
                }

                var scenes = EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).ToArray();
                if (scenes.Length == 0)
                    throw new Exception("No enabled scenes in Build Settings.");

                var outPath = Environment.GetEnvironmentVariable("UNITY_BUILD_OUT");
                if (string.IsNullOrEmpty(outPath))
                    outPath = "Builds/" + PlayerSettings.productName.Replace(" ", "") + ".aab";
                var dir = Path.GetDirectoryName(outPath);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

                var report = BuildPipeline.BuildPlayer(new BuildPlayerOptions
                {
                    scenes = scenes,
                    locationPathName = outPath,
                    target = BuildTarget.Android,
                    options = BuildOptions.None
                });

                var ok = report.summary.result == BuildResult.Succeeded;
                UnityEngine.Debug.Log("Build result: " + report.summary.result + ", output: " + outPath);
                EditorApplication.Exit(ok ? 0 : 1);
            }
            catch (Exception e)
            {
                UnityEngine.Debug.LogError("BuildFailedException: " + e);
                EditorApplication.Exit(1);
            }
        }

        static void ApplySigningFromEnvironment()
        {
            var keystore = Environment.GetEnvironmentVariable("UNITY_KEYSTORE_PATH");
            if (string.IsNullOrEmpty(keystore)) return; // use whatever Player Settings already has

            PlayerSettings.Android.useCustomKeystore = true;
            PlayerSettings.Android.keystoreName = keystore;
            PlayerSettings.Android.keystorePass = Environment.GetEnvironmentVariable("UNITY_KEYSTORE_PASS") ?? "";
            PlayerSettings.Android.keyaliasName = Environment.GetEnvironmentVariable("UNITY_KEYALIAS_NAME") ?? "";
            PlayerSettings.Android.keyaliasPass = Environment.GetEnvironmentVariable("UNITY_KEYALIAS_PASS") ?? "";
        }
    }
}

using System;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

namespace JuicyBuildKit
{
    /// <summary>
    /// Fails an Android build in seconds (instead of after a 15 minute Gradle run) when:
    ///  - loose androidx.*.aar / androidx.*.jar files sit in Assets/ or Packages/ (duplicate-class errors), or
    ///  - Target API Level is Automatic or lower than the project's floor (the value Unity reports is the effective one,
    ///    including any Unity 6 Build Profile override), or
    ///  - a batch build uses a custom keystore but no keystore password was supplied.
    /// The floor is UNITY_KIT_MIN_TARGET_API (environment variable, else .unity-kit.env in the project root, else 36).
    /// It is a minimum, not a pin: set a higher Target API Level in Player Settings at any time.
    /// </summary>
    public class Preflight : IPreprocessBuildWithReport
    {
        public const int DefaultMinTargetApi = 36;
        const string FloorKey = "UNITY_KIT_MIN_TARGET_API";

        public int callbackOrder => -1000;

        public void OnPreprocessBuild(BuildReport report)
        {
            if (report.summary.platform != BuildTarget.Android) return;

            var stray = new[] { "Assets", "Packages" }
                .Where(Directory.Exists)
                .SelectMany(d => Directory.GetFiles(d, "androidx.*", SearchOption.AllDirectories))
                .Where(f => f.EndsWith(".aar", StringComparison.OrdinalIgnoreCase) ||
                            f.EndsWith(".jar", StringComparison.OrdinalIgnoreCase))
                .ToArray();

            if (stray.Length > 0)
            {
                throw new BuildFailedException(
                    "Preflight: stray AndroidX files would duplicate Maven dependencies:\n" +
                    string.Join("\n", stray) +
                    "\nDelete them (and their .meta files), then run Android Resolver > Force Resolve.");
            }

            var min = ResolveMinTargetApi();
            var levelName = PlayerSettings.Android.targetSdkVersion.ToString(); // e.g. AndroidApiLevel37, AndroidApiLevelAuto
            var match = Regex.Match(levelName, @"AndroidApiLevel(\d+)$");

            if (!match.Success)
            {
                throw new BuildFailedException(
                    "Preflight: Target API Level must be set explicitly to " + min + " or higher " +
                    "(Player Settings > Android > Other Settings). Current: " + levelName);
            }

            var target = int.Parse(match.Groups[1].Value);
            if (target < min)
            {
                throw new BuildFailedException(
                    "Preflight: Target API Level is " + target + " but this project requires at least " + min +
                    " (" + FloorKey + " in .unity-kit.env). Raise it in Player Settings, or lower the floor deliberately.");
            }

            // Unity does not save keystore passwords in the project. In a batch build nobody can type them, so fail
            // now with a clear message instead of after the Gradle prerequisites ("Unable to sign the Android application").
            if (Application.isBatchMode &&
                PlayerSettings.Android.useCustomKeystore &&
                string.IsNullOrEmpty(PlayerSettings.Android.keystorePass))
            {
                throw new BuildFailedException(
                    "Preflight: a custom keystore is enabled but no keystore password is set. For batch builds put " +
                    "UNITY_KEYSTORE_PATH, UNITY_KEYSTORE_PASS, UNITY_KEYALIAS_NAME and UNITY_KEYALIAS_PASS in " +
                    "~/.config/unity-kit/projects/<ProjectFolder>.env (private, outside git) and run tools/build-aab.sh.");
            }
        }

        public static int ResolveMinTargetApi()
        {
            int v;
            if (int.TryParse(Environment.GetEnvironmentVariable(FloorKey), out v) && v > 0) return v;

            var projectRoot = Directory.GetParent(Application.dataPath).FullName;
            var file = Path.Combine(projectRoot, ".unity-kit.env");
            if (File.Exists(file))
            {
                foreach (var raw in File.ReadAllLines(file))
                {
                    var line = raw.Trim();
                    if (line.StartsWith("#") || !line.StartsWith(FloorKey + "=")) continue;
                    var val = line.Substring(line.IndexOf('=') + 1).Trim().Trim('"', '\'');
                    if (int.TryParse(val, out v) && v > 0) return v;
                }
            }
            return DefaultMinTargetApi;
        }
    }
}

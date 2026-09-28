package opensource.wild

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Keeps exactly one launcher alias enabled; Android persists the component state. */
internal class LauncherIconChannel(context: Context, messenger: BinaryMessenger) {
    private val appContext = context.applicationContext
    private val aliases = linkedMapOf(
        "iris" to "opensource.wild.LauncherIris",
        "blue" to "opensource.wild.LauncherBlue",
        "rose" to "opensource.wild.LauncherRose",
        "orange" to "opensource.wild.LauncherOrange",
        "teal" to "opensource.wild.LauncherTeal",
        "green" to "opensource.wild.LauncherGreen",
    )

    init {
        MethodChannel(messenger, "litetale/launcher_icon").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getIcon" -> result.success(currentIcon())
                    "setIcon" -> {
                        val name = call.arguments as? String
                        if (name == null || !aliases.containsKey(name)) {
                            result.error("invalid_icon", "Unknown launcher icon", null)
                        } else {
                            selectIcon(name)
                            result.success(name)
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("launcher_icon_failed", error.message, null)
            }
        }
    }

    private fun component(className: String) = ComponentName(appContext.packageName, className)

    private fun currentIcon(): String {
        val manager = appContext.packageManager
        for ((name, className) in aliases) {
            val state = manager.getComponentEnabledSetting(component(className))
            if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED ||
                (name == "iris" && state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT)
            ) return name
        }
        return "iris"
    }

    private fun selectIcon(selected: String) {
        if (currentIcon() == selected) return
        val manager = appContext.packageManager
        val flags = PackageManager.DONT_KILL_APP
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            manager.setComponentEnabledSettings(
                aliases.map { (name, className) ->
                    PackageManager.ComponentEnabledSetting(
                        component(className),
                        if (name == selected) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                        else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                        flags,
                    )
                },
            )
        } else {
            // Enable first, so even an older launcher never loses the icon.
            manager.setComponentEnabledSetting(
                component(aliases.getValue(selected)),
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                flags,
            )
            for ((name, className) in aliases) {
                if (name == selected) continue
                manager.setComponentEnabledSetting(
                    component(className),
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    flags,
                )
            }
        }
    }
}

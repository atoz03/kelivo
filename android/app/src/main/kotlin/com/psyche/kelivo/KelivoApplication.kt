package com.psyche.kelivo

import android.app.Application
import com.psyche.kelivo.background.BackgroundRuntime
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

/** One Dart isolate and database owner per process, independent of its UI. */
class KelivoApplication : Application() {
    val backgroundRuntime by lazy { BackgroundRuntime(this) }
    val deviceTools by lazy { DeviceLocalToolsHandler(this) }

    private val engineHolder = lazy {
        FlutterEngine(this).also { engine ->
            val messenger = engine.dartExecutor.binaryMessenger
            backgroundRuntime.configure(messenger)
            deviceTools.configure(messenger)
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        }
    }

    val hasEngine get() = engineHolder.isInitialized()
    val engine: FlutterEngine get() = engineHolder.value
}

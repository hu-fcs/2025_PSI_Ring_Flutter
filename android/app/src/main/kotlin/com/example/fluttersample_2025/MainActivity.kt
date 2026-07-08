package com.example.fluttersample_2025

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "app.maps"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "openMap") {
                    val lat = call.argument<Double>("lat")
                    val lon = call.argument<Double>("lon")

                    if (lat == null || lon == null) {
                        result.error("ARG_ERROR", "lat or lon is null", null)
                        return@setMethodCallHandler
                    }

                    try {
                        // ① geo: URI（まずは地図アプリを試す）
                        val geoUri = Uri.parse("geo:$lat,$lon?q=$lat,$lon")
                        val geoIntent = Intent(Intent.ACTION_VIEW, geoUri)
                        geoIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(geoIntent)

                        result.success(true)
                    } catch (e: Exception) {
                        try {
                            // ② フォールバック：Google Maps Web（必ず開く）
                            val webUri = Uri.parse(
                                "https://www.google.com/maps/search/?api=1&query=$lat,$lon"
                            )
                            val webIntent = Intent(Intent.ACTION_VIEW, webUri)
                            webIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(webIntent)

                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("FAIL", "Failed to open map", null)
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }
    }
}

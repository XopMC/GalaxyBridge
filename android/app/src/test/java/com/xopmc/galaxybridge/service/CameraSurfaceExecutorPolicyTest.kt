package com.xopmc.galaxybridge.service

import java.nio.file.Files
import java.nio.file.Path
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraSurfaceExecutorPolicyTest {
    @Test
    fun surfaceCompletionDoesNotTargetTheServiceWorkerThatIsShutDownOnDestroy() {
        val source = Files.readString(
            Path.of(
                System.getProperty("user.dir"),
                "src",
                "main",
                "java",
                "com",
                "xopmc",
                "galaxybridge",
                "service",
                "CameraCaptureService.kt",
            ),
        )

        assertTrue(
            "SurfaceRequest completion must use an executor that remains alive while CameraX finishes unbinding",
            Regex(
                "request\\.provideSurface\\(\\s*activeEncoder\\.surface,\\s*" +
                    "ContextCompat\\.getMainExecutor\\(this\\)",
            ).containsMatchIn(source),
        )
        assertFalse(
            "shutting down cameraExecutor during onDestroy races CameraX's completion callback",
            Regex(
                "request\\.provideSurface\\(\\s*activeEncoder\\.surface,\\s*cameraExecutor",
            ).containsMatchIn(source),
        )
    }
}

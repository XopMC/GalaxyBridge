package com.xopmc.galaxybridge.transport.shell

import java.io.IOException
import java.io.EOFException
import org.junit.Assert.*
import org.junit.Test

class ShellActivationDiagnosticsTest {
    @Test fun stageAndRecognizedCauseRemainFixedAndNeverExposePrivateMessages() {
        val privateText = "private endpoint/token fixture"
        val cases = listOf(
            ShellActivationStage.CONNECT to IOException(privateText, UnsupportedOperationException(privateText)),
            ShellActivationStage.PEER_UID to IllegalStateException(privateText),
            ShellActivationStage.OWNER_WRITE to IOException(privateText),
            ShellActivationStage.OWNER_READ to EOFException(privateText),
            ShellActivationStage.READY_CHECK to IllegalStateException(privateText))
        val expected = listOf("connect_unsupported", "peer_uid_rejected", "owner_write_io", "owner_read_eof", "ready_check_rejected")
        cases.zip(expected).forEach { (input, suffix) ->
            val code = ShellActivationDiagnostics.publicCode(ShellActivationFailure(input.first, input.second))
            assertEquals("shell_activation_$suffix", code)
            assertTrue(code.length <= 80)
            assertFalse(code.contains(privateText))
        }
        assertEquals("shell_activation_failed", ShellActivationDiagnostics.publicCode(IOException(privateText)))
    }
    @Test fun nativeStrerrorWithoutErrnoCauseMapsOnlyToFixedCodes() {
        val messages = mapOf("Permission denied" to "eacces", "Operation not permitted" to "eperm",
            "Connection refused" to "econnrefused", "No such file or directory" to "enoent",
            "Connection timed out" to "timeout", "Connection reset by peer" to "reset", "Broken pipe" to "epipe",
            "connect failed: EACCES (Permission denied)" to "eacces", "ECONNREFUSED" to "econnrefused")
        messages.forEach { (message, category) ->
            val error = IOException("shell_connect_failed", IOException(message))
            assertEquals("shell_activation_connect_$category", ShellActivationDiagnostics.publicCode(
                ShellActivationFailure(ShellActivationStage.CONNECT, error)))
        }
    }
    @Test fun attackerTextAndUnknownIoMessagesNeverAppearInReceipt() {
        val privateText = "fixture-token/private-name/\nmalicious-receipt"
        for (message in listOf(privateText, "Permission denied $privateText", "EACCES $privateText", "xEACCESy $privateText")) {
            val code = ShellActivationDiagnostics.publicCode(ShellActivationFailure(ShellActivationStage.CONNECT, IOException(message)))
            assertTrue(code in setOf("shell_activation_connect_io", "shell_activation_connect_eacces"))
            assertFalse(code.contains(privateText))
        }
        assertEquals("shell_activation_connect_io", ShellActivationDiagnostics.publicCode(
            ShellActivationFailure(ShellActivationStage.CONNECT, IOException("xEACCESy"))))
    }

    @Test fun timeoutAndCancellationAreClassifiedWithoutLeakingConnectCause() {
        assertEquals("shell_activation_connect_timeout", ShellActivationDiagnostics.publicCode(
            ShellActivationFailure(ShellActivationStage.CONNECT, IOException("shell_connect_timeout"))))
        assertEquals("shell_activation_connect_cancelled", ShellActivationDiagnostics.publicCode(
            ShellActivationFailure(ShellActivationStage.CONNECT, IOException("shell_connect_cancelled"))))
        assertEquals("shell_activation_connect_security", ShellActivationDiagnostics.publicCode(
            ShellActivationFailure(ShellActivationStage.CONNECT, IOException("opaque", SecurityException("private fixture")))))
    }
}

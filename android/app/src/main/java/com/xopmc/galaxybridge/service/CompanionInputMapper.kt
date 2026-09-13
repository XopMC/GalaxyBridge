package com.xopmc.galaxybridge.service

import kotlin.math.abs
import kotlin.math.max
import java.util.concurrent.ConcurrentHashMap

internal const val META_CTRL_ON = 0x0000_1000

data class TextEditResult(val text: String, val selection: Int)

sealed interface AndroidInputCommand {
    val displayEpoch: Int

    data class Tap(
        val normalizedX: Double,
        val normalizedY: Double,
        override val displayEpoch: Int,
    ) : AndroidInputCommand

    data class Swipe(
        val fromX: Double,
        val fromY: Double,
        val toX: Double,
        val toY: Double,
        val durationMillis: Long,
        override val displayEpoch: Int,
    ) : AndroidInputCommand

    data class Scroll(
        val normalizedX: Double,
        val normalizedY: Double,
        val scrollX: Double,
        val scrollY: Double,
        override val displayEpoch: Int,
    ) : AndroidInputCommand

    data class Key(
        val androidKeycode: Int,
        val modifiers: Int,
        override val displayEpoch: Int,
    ) : AndroidInputCommand

    data class Text(
        val text: String,
        override val displayEpoch: Int,
    ) : AndroidInputCommand

    data class Global(
        val action: GlobalAction,
        override val displayEpoch: Int,
    ) : AndroidInputCommand
}

enum class GlobalAction { BACK, HOME, RECENTS, NOTIFICATIONS, QUICK_SETTINGS }

class CompanionPointerGestureAccumulator {
    private val starts = ConcurrentHashMap<Long, Pair<Double, Double>>()

    fun down(pointerId: Long, x: Double, y: Double) {
        starts[pointerId] = safePoint(x, y)
    }

    fun move(pointerId: Long, x: Double, y: Double) {
        starts.putIfAbsent(pointerId, safePoint(x, y))
    }

    fun up(pointerId: Long, x: Double, y: Double, displayEpoch: Int): AndroidInputCommand {
        val end = safePoint(x, y)
        val start = starts.remove(pointerId) ?: end
        val distance = abs(start.first - end.first) + abs(start.second - end.second)
        return if (distance < TAP_DISTANCE) {
            AndroidInputCommand.Tap(end.first, end.second, displayEpoch)
        } else {
            AndroidInputCommand.Swipe(
                fromX = start.first,
                fromY = start.second,
                toX = end.first,
                toY = end.second,
                durationMillis = SWIPE_DURATION_MILLIS,
                displayEpoch = displayEpoch,
            )
        }
    }

    fun cancel(pointerId: Long) {
        starts.remove(pointerId)
    }

    private fun safePoint(x: Double, y: Double): Pair<Double, Double> =
        x.takeIf(Double::isFinite)?.coerceIn(0.0, 1.0).orZero() to
            y.takeIf(Double::isFinite)?.coerceIn(0.0, 1.0).orZero()

    private fun Double?.orZero() = this ?: 0.0

    private companion object {
        const val TAP_DISTANCE = 0.01
        const val SWIPE_DURATION_MILLIS = 120L
    }
}

sealed interface AccessibilityKeyOperation {
    data class Global(val action: GlobalAction) : AccessibilityKeyOperation
    data object Enter : AccessibilityKeyOperation
    data object TabForward : AccessibilityKeyOperation
    data object InsertSpace : AccessibilityKeyOperation
    data object DeleteBackward : AccessibilityKeyOperation
    data object DeleteForward : AccessibilityKeyOperation
    data object MoveLeft : AccessibilityKeyOperation
    data object MoveRight : AccessibilityKeyOperation
    data object MoveUp : AccessibilityKeyOperation
    data object MoveDown : AccessibilityKeyOperation
    data object MoveHome : AccessibilityKeyOperation
    data object MoveEnd : AccessibilityKeyOperation
    data object PageUp : AccessibilityKeyOperation
    data object PageDown : AccessibilityKeyOperation
    data object SelectAll : AccessibilityKeyOperation
    data object Copy : AccessibilityKeyOperation
    data object Paste : AccessibilityKeyOperation
    data object Cut : AccessibilityKeyOperation
}

object CompanionInputMapper {
    private const val MAX_SCROLL_DELTA = 16.0
    private const val NORMALIZED_DISTANCE_PER_SCROLL_UNIT = 0.025
    private const val MIN_SCROLL_DURATION_MS = 48L
    private const val MAX_SCROLL_DURATION_MS = 160L

    fun scrollSwipe(
        centerX: Double,
        centerY: Double,
        scrollX: Double,
        scrollY: Double,
        displayEpoch: Int,
    ): AndroidInputCommand.Swipe? {
        if (!centerX.isFinite() || !centerY.isFinite() || !scrollX.isFinite() || !scrollY.isFinite()) return null
        val safeX = scrollX.coerceIn(-MAX_SCROLL_DELTA, MAX_SCROLL_DELTA)
        val safeY = scrollY.coerceIn(-MAX_SCROLL_DELTA, MAX_SCROLL_DELTA)
        val strength = max(abs(safeX), abs(safeY))
        if (strength < 0.01) return null
        val deltaX = safeX * NORMALIZED_DISTANCE_PER_SCROLL_UNIT
        val deltaY = safeY * NORMALIZED_DISTANCE_PER_SCROLL_UNIT
        val x = centerX.coerceIn(0.0, 1.0)
        val y = centerY.coerceIn(0.0, 1.0)
        val duration = MIN_SCROLL_DURATION_MS +
            ((MAX_SCROLL_DURATION_MS - MIN_SCROLL_DURATION_MS) * strength / MAX_SCROLL_DELTA).toLong()
        return AndroidInputCommand.Swipe(
            fromX = (x - deltaX / 2).coerceIn(0.0, 1.0),
            fromY = (y - deltaY / 2).coerceIn(0.0, 1.0),
            toX = (x + deltaX / 2).coerceIn(0.0, 1.0),
            toY = (y + deltaY / 2).coerceIn(0.0, 1.0),
            durationMillis = duration,
            displayEpoch = displayEpoch,
        )
    }

    fun keyOperation(androidKeycode: Int, modifiers: Int): AccessibilityKeyOperation? {
        if (modifiers and META_CTRL_ON != 0) {
            return when (androidKeycode) {
                29 -> AccessibilityKeyOperation.SelectAll
                31 -> AccessibilityKeyOperation.Copy
                50 -> AccessibilityKeyOperation.Paste
                52 -> AccessibilityKeyOperation.Cut
                else -> null
            }
        }
        return when (androidKeycode) {
            4 -> AccessibilityKeyOperation.Global(GlobalAction.BACK)
            3 -> AccessibilityKeyOperation.Global(GlobalAction.HOME)
            187 -> AccessibilityKeyOperation.Global(GlobalAction.RECENTS)
            83 -> AccessibilityKeyOperation.Global(GlobalAction.NOTIFICATIONS)
            66 -> AccessibilityKeyOperation.Enter
            61 -> AccessibilityKeyOperation.TabForward
            62 -> AccessibilityKeyOperation.InsertSpace
            67 -> AccessibilityKeyOperation.DeleteBackward
            112 -> AccessibilityKeyOperation.DeleteForward
            21 -> AccessibilityKeyOperation.MoveLeft
            22 -> AccessibilityKeyOperation.MoveRight
            19 -> AccessibilityKeyOperation.MoveUp
            20 -> AccessibilityKeyOperation.MoveDown
            122 -> AccessibilityKeyOperation.MoveHome
            123 -> AccessibilityKeyOperation.MoveEnd
            92 -> AccessibilityKeyOperation.PageUp
            93 -> AccessibilityKeyOperation.PageDown
            else -> null
        }
    }

    fun replaceSelection(
        text: String,
        selectionStart: Int,
        selectionEnd: Int,
        replacement: String,
    ): TextEditResult {
        val (start, end) = normalizedSelection(text.length, selectionStart, selectionEnd)
        return TextEditResult(
            text = text.replaceRange(start, end, replacement),
            selection = start + replacement.length,
        )
    }

    fun deleteSelection(
        text: String,
        selectionStart: Int,
        selectionEnd: Int,
        backward: Boolean,
    ): TextEditResult {
        val (selectionStartSafe, selectionEndSafe) = normalizedSelection(text.length, selectionStart, selectionEnd)
        val (start, end) = when {
            selectionStartSafe != selectionEndSafe -> selectionStartSafe to selectionEndSafe
            backward && selectionStartSafe > 0 ->
                Character.offsetByCodePoints(text, selectionStartSafe, -1) to selectionStartSafe
            !backward && selectionStartSafe < text.length ->
                selectionStartSafe to Character.offsetByCodePoints(text, selectionStartSafe, 1)
            else -> return TextEditResult(text, selectionStartSafe)
        }
        return TextEditResult(text.removeRange(start, end), start)
    }

    private fun normalizedSelection(textLength: Int, rawStart: Int, rawEnd: Int): Pair<Int, Int> {
        if (rawStart !in 0..textLength || rawEnd !in 0..textLength) return textLength to textLength
        return minOf(rawStart, rawEnd) to maxOf(rawStart, rawEnd)
    }
}

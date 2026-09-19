package com.xopmc.galaxybridge.service

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.util.concurrent.atomic.AtomicReference

class GalaxyAccessibilityService : AccessibilityService() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val remoteEditableShadow = RemoteEditableShadow(REMOTE_EDIT_SHADOW_MILLIS)
    private val inputTimeouts = mutableMapOf<Long, Runnable>()
    private var inputQueue: RemoteInputCompletionQueue = newInputQueue()

    private fun newInputQueue() = RemoteInputCompletionQueue(
        execute = ::executeInput,
        scheduleTimeout = { ticket, delay ->
            val queue = inputQueue
            val work = Runnable { inputTimeouts.remove(ticket); queue.timeout(ticket) }
            inputTimeouts[ticket] = work
            mainHandler.postDelayed(work, delay)
        },
        cancelTimeout = { ticket -> inputTimeouts.remove(ticket)?.let(mainHandler::removeCallbacks) },
    )
    private var mostRecentlyFocusedWindowID: Int? = null

    override fun onServiceConnected() {
        inputQueue.close()
        inputQueue = newInputQueue()
        active.set(this)
        remoteKeyboardMode.reapply()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        inputQueue.close()
        remoteEditableShadow.invalidate()
        active.compareAndSet(this, null)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        inputQueue.close()
        remoteEditableShadow.invalidate()
        applyRemoteKeyboardMode(hidden = false)
        active.compareAndSet(this, null)
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType == AccessibilityEvent.TYPE_VIEW_FOCUSED && event.windowId >= 0) {
            mostRecentlyFocusedWindowID = event.windowId
        }
    }

    override fun onInterrupt() {
        inputQueue.abortPending()
        remoteEditableShadow.invalidate()
    }

    private fun applyRemoteKeyboardMode(hidden: Boolean) {
        runCatching {
            softKeyboardController.setShowMode(
                if (hidden) SHOW_MODE_HIDDEN else SHOW_MODE_AUTO,
            )
        }
    }

    private fun executeInput(command: AndroidInputCommand, ticket: Long): RemoteInputCompletionQueue.Execution {
        if (command is AndroidInputCommand.Tap || command is AndroidInputCommand.Swipe ||
            command is AndroidInputCommand.Scroll || command is AndroidInputCommand.Global
        ) remoteEditableShadow.invalidate()
        val swipe = when (command) {
            is AndroidInputCommand.Tap -> AndroidInputCommand.Swipe(
                command.normalizedX, command.normalizedY, command.normalizedX, command.normalizedY, 1, command.displayEpoch)
            is AndroidInputCommand.Swipe -> command
            is AndroidInputCommand.Scroll -> CompanionInputMapper.scrollSwipe(
                command.normalizedX, command.normalizedY, command.scrollX, command.scrollY, command.displayEpoch)
            else -> null
        }
        if (swipe != null) {
            val queue = inputQueue
            val callback = object : GestureResultCallback() {
                override fun onCompleted(description: GestureDescription?) = queue.completed(ticket, true)
                override fun onCancelled(description: GestureDescription?) = queue.completed(ticket, false)
            }
            val duration = swipe.durationMillis.coerceIn(1, 60_000)
            return if (gesture(swipe.fromX, swipe.fromY, swipe.toX, swipe.toY, duration, callback)) {
                RemoteInputCompletionQueue.Execution.Gesture(duration + 1_000)
            } else RemoteInputCompletionQueue.Execution.Rejected
        }
        val handled = when (command) {
            is AndroidInputCommand.Text -> injectTextNow(command.text)
            is AndroidInputCommand.Key -> injectKey(command.androidKeycode, command.modifiers)
            is AndroidInputCommand.Global -> injectGlobal(command.action)
            is AndroidInputCommand.Scroll -> true // zero-distance scroll
            else -> false
        }
        return if (handled) RemoteInputCompletionQueue.Execution.Completed else RemoteInputCompletionQueue.Execution.Rejected
    }

    private fun injectGlobal(action: GlobalAction): Boolean = performGlobalAction(
        when (action) {
            GlobalAction.BACK -> GLOBAL_ACTION_BACK
            GlobalAction.HOME -> GLOBAL_ACTION_HOME
            GlobalAction.RECENTS -> GLOBAL_ACTION_RECENTS
            GlobalAction.NOTIFICATIONS -> GLOBAL_ACTION_NOTIFICATIONS
            GlobalAction.QUICK_SETTINGS -> GLOBAL_ACTION_QUICK_SETTINGS
        },
    )

    private fun gesture(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        duration: Long,
        callback: GestureResultCallback? = null,
    ): Boolean {
        val metrics = resources.displayMetrics
        fun x(value: Double) = (value.coerceIn(0.0, 1.0) * (metrics.widthPixels - 1)).toFloat()
        fun y(value: Double) = (value.coerceIn(0.0, 1.0) * (metrics.heightPixels - 1)).toFloat()
        val path = Path().apply {
            moveTo(x(fromX), y(fromY))
            lineTo(x(toX), y(toY))
        }
        return dispatchGesture(
            GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, duration))
                .build(),
            callback,
            mainHandler,
        )
    }

    private fun injectTextNow(text: String): Boolean {
        if (text.isEmpty()) return true
        val delivered = editableNode()?.let { replaceSelection(it, text) } == true
        Log.i(INPUT_LOG_TAG, "text delivery bytes=${text.toByteArray().size} delivered=$delivered")
        return delivered
    }

    private fun injectKey(androidKeycode: Int, modifiers: Int): Boolean =
        when (val operation = CompanionInputMapper.keyOperation(androidKeycode, modifiers)) {
            is AccessibilityKeyOperation.Global -> {
                remoteEditableShadow.invalidate()
                injectGlobal(operation.action)
            }
            AccessibilityKeyOperation.Enter -> {
                val focused = editableNode() ?: return false
                focused.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id) ||
                    (focused.isMultiLine && replaceSelection(focused, "\n"))
            }
            AccessibilityKeyOperation.TabForward -> moveFocus(View.FOCUS_FORWARD)
            AccessibilityKeyOperation.InsertSpace -> injectTextNow(" ")
            AccessibilityKeyOperation.DeleteBackward -> deleteFromSelection(backward = true)
            AccessibilityKeyOperation.DeleteForward -> deleteFromSelection(backward = false)
            AccessibilityKeyOperation.MoveLeft -> moveHorizontal(forward = false)
            AccessibilityKeyOperation.MoveRight -> moveHorizontal(forward = true)
            AccessibilityKeyOperation.MoveUp -> moveFocus(View.FOCUS_UP)
            AccessibilityKeyOperation.MoveDown -> moveFocus(View.FOCUS_DOWN)
            AccessibilityKeyOperation.MoveHome -> moveToBoundary(end = false)
            AccessibilityKeyOperation.MoveEnd -> moveToBoundary(end = true)
            AccessibilityKeyOperation.PageUp -> scrollFocused(forward = false)
            AccessibilityKeyOperation.PageDown -> scrollFocused(forward = true)
            AccessibilityKeyOperation.SelectAll -> selectAll()
            AccessibilityKeyOperation.Copy -> copyOrCutSelection(AccessibilityNodeInfo.ACTION_COPY)
            AccessibilityKeyOperation.Paste -> editableNode()?.performAction(AccessibilityNodeInfo.ACTION_PASTE) == true
            AccessibilityKeyOperation.Cut -> copyOrCutSelection(AccessibilityNodeInfo.ACTION_CUT)
            null -> false
        }

    private fun copyOrCutSelection(action: Int): Boolean {
        val focused = editableNode() ?: return false
        val current = editorSnapshot(focused, editorKey(focused))
        val payload = AccessibilitySelectionClipboard.payload(
            text = current.text,
            selectionStart = current.selectionStart,
            selectionEnd = current.selectionEnd,
            isPassword = focused.isPassword,
            generation = SystemClock.elapsedRealtimeNanos(),
            tracker = ClipboardBridge.changeTracker,
        )
        val handled = focused.performAction(action)
        if (AccessibilitySelectionClipboard.shouldPublish(
                isCopy = action == AccessibilityNodeInfo.ACTION_COPY,
                actionHandled = handled,
                payloadAvailable = payload != null,
            ) && payload != null
        ) {
            ClipboardBridge.outboundHub.publish(payload)
        }
        return handled || (action == AccessibilityNodeInfo.ACTION_COPY && payload != null)
    }

    private fun editableNode(): AccessibilityNodeInfo? {
        val activeRoot = rootInActiveWindow
        val interactiveWindows = windows.orEmpty()
        val rootsByWindowID = buildMap {
            if (activeRoot != null) put(activeRoot.windowId, activeRoot)
            interactiveWindows.forEach { window ->
                window.root?.let { root -> put(window.id, root) }
            }
        }
        val orderedWindowIDs = AccessibilityWindowSearchOrder.windowIds(
            activeWindowId = activeRoot?.windowId,
            preferredWindowId = mostRecentlyFocusedWindowID,
            windows = interactiveWindows.map { window ->
                AccessibilityWindowCandidate(windowId = window.id, focused = window.isFocused)
            },
        )
        val editable = orderedWindowIDs.firstNotNullOfOrNull { windowID ->
            rootsByWindowID[windowID]
                ?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                ?.takeIf(::isEditableNode)
        }
        Log.i(
            INPUT_LOG_TAG,
            "editable search active=${activeRoot?.windowId ?: -1} preferred=${mostRecentlyFocusedWindowID ?: -1} focused=${interactiveWindows.filter { it.isFocused }.joinToString { it.id.toString() }} ordered=${orderedWindowIDs.joinToString()} found=${editable != null}",
        )
        return editable
    }

    private fun isEditableNode(node: AccessibilityNodeInfo): Boolean =
        node.isEditable || node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }

    private fun replaceSelection(focused: AccessibilityNodeInfo, replacement: String): Boolean {
        val editorKey = editorKey(focused)
        val current = editorSnapshot(focused, editorKey)
        val edit = CompanionInputMapper.replaceSelection(
            current.text,
            current.selectionStart,
            current.selectionEnd,
            replacement,
        )
        return applyEdit(focused, editorKey, edit)
    }

    private fun deleteFromSelection(backward: Boolean): Boolean {
        val focused = editableNode() ?: return false
        val editorKey = editorKey(focused)
        val current = editorSnapshot(focused, editorKey)
        val edit = CompanionInputMapper.deleteSelection(
            current.text,
            current.selectionStart,
            current.selectionEnd,
            backward,
        )
        if (edit.text == current.text) return true
        return applyEdit(focused, editorKey, edit)
    }

    private fun applyEdit(
        focused: AccessibilityNodeInfo,
        editorKey: String,
        edit: TextEditResult,
    ): Boolean {
        val arguments = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, edit.text)
        }
        if (!focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)) return false
        remoteEditableShadow.applied(
            editorKey = editorKey,
            edit = edit,
            nowMillis = SystemClock.uptimeMillis(),
        )
        setSelection(focused, edit.selection)
        return true
    }

    private fun moveHorizontal(forward: Boolean): Boolean {
        val focused = editableNode() ?: return moveFocus(if (forward) View.FOCUS_RIGHT else View.FOCUS_LEFT)
        val current = editorSnapshot(focused, editorKey(focused))
        val selection = current.selectionStart until current.selectionEnd
        val next = when {
            !selection.isEmpty() && forward -> selection.last + 1
            !selection.isEmpty() -> selection.first
            forward && selection.first < current.text.length -> Character.offsetByCodePoints(current.text, selection.first, 1)
            !forward && selection.first > 0 -> Character.offsetByCodePoints(current.text, selection.first, -1)
            else -> selection.first
        }
        return setSelection(focused, next)
    }

    private fun moveToBoundary(end: Boolean): Boolean {
        val focused = editableNode() ?: return false
        return setSelection(focused, if (end) editableText(focused).length else 0)
    }

    private fun selectAll(): Boolean {
        val focused = editableNode() ?: return false
        return setSelection(focused, 0, editableText(focused).length)
    }

    private fun editableText(focused: AccessibilityNodeInfo): String = AccessibilityEditableText.current(
        text = focused.text?.toString().orEmpty(),
        isShowingHintText = focused.isShowingHintText,
    )

    private fun editorKey(focused: AccessibilityNodeInfo): String = buildString {
        append(focused.windowId)
        append(':')
        append(focused.packageName?.toString().orEmpty())
        append(':')
        append(focused.viewIdResourceName.orEmpty())
        append(':')
        append(focused.className?.toString().orEmpty())
    }

    private fun editorSnapshot(focused: AccessibilityNodeInfo, editorKey: String): EditorSnapshot =
        remoteEditableShadow.resolve(
            editorKey = editorKey,
            observedText = editableText(focused),
            observedSelectionStart = focused.textSelectionStart,
            observedSelectionEnd = focused.textSelectionEnd,
            nowMillis = SystemClock.uptimeMillis(),
        )

    private fun setSelection(focused: AccessibilityNodeInfo, start: Int, end: Int = start): Boolean {
        val arguments = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
        }
        if (!focused.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, arguments)) return false
        remoteEditableShadow.selected(
            editorKey = editorKey(focused),
            observedText = editableText(focused),
            selectionStart = start,
            selectionEnd = end,
            nowMillis = SystemClock.uptimeMillis(),
        )
        return true
    }

    private fun moveFocus(direction: Int): Boolean {
        val root = rootInActiveWindow ?: return false
        val current = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: root.findFocus(AccessibilityNodeInfo.FOCUS_ACCESSIBILITY)
            ?: root
        val next = current.focusSearch(direction) ?: return false
        return next.performAction(AccessibilityNodeInfo.ACTION_FOCUS) ||
            next.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS)
    }

    private fun scrollFocused(forward: Boolean): Boolean {
        var node = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: rootInActiveWindow
        val action = if (forward) AccessibilityNodeInfo.ACTION_SCROLL_FORWARD else AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
        while (node != null) {
            if (node.actionList.any { it.id == action } && node.performAction(action)) return true
            node = node.parent
        }
        return false
    }

    companion object {
        private const val INPUT_LOG_TAG = "GalaxyBridgeInput"
        private const val REMOTE_EDIT_SHADOW_MILLIS = 1_000L
        private val active = AtomicReference<GalaxyAccessibilityService?>()
        private val remoteKeyboardMode = RemoteSoftKeyboardModeController { hidden ->
            active.get()?.let { service ->
                service.mainHandler.post { service.applyRemoteKeyboardMode(hidden) }
            }
        }

        fun isActive(): Boolean = active.get() != null

        fun injectTextImmediately(text: String): Boolean {
            val service = active.get() ?: return false
            // BroadcastReceiver.onReceive runs on the application main looper;
            // keeping this synchronous lets adb distinguish delivery from a
            // disabled Accessibility service and use its safe fallback.
            if (Looper.myLooper() != Looper.getMainLooper()) return false
            if (!service.inputQueue.isIdle) return false
            return service.injectTextNow(text)
        }

        fun setRemoteKeyboardCaptureActive(active: Boolean) {
            remoteKeyboardMode.setCaptureActive(active)
        }

        fun submit(command: AndroidInputCommand): Boolean {
            val service = active.get() ?: return false
            if (Looper.myLooper() == Looper.getMainLooper()) return service.inputQueue.enqueue(command)
            val queue = service.inputQueue
            return service.mainHandler.post {
                if (active.get() === service && service.inputQueue === queue) queue.enqueue(command)
            }
        }
    }
}

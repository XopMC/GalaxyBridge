package com.xopmc.galaxybridge.service

import android.inputmethodservice.InputMethodService
import android.view.View
import android.widget.TextView
import com.xopmc.galaxybridge.R
import java.util.concurrent.atomic.AtomicReference

class GalaxyBridgeImeService : InputMethodService() {
    override fun onCreate() {
        super.onCreate()
        active.set(this)
    }

    override fun onDestroy() {
        active.compareAndSet(this, null)
        super.onDestroy()
    }

    override fun onCreateInputView(): View = TextView(this).apply {
        setText(R.string.app_name)
        textAlignment = View.TEXT_ALIGNMENT_CENTER
        setPadding(24, 24, 24, 24)
    }

    companion object {
        private val active = AtomicReference<GalaxyBridgeImeService?>()

        fun isActive(): Boolean = active.get() != null

        fun commitText(text: String): Boolean {
            val connection = active.get()?.currentInputConnection ?: return false
            return connection.commitText(text, 1)
        }
    }
}

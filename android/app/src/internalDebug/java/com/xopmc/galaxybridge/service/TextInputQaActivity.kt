package com.xopmc.galaxybridge.service

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.text.InputType
import android.util.Log
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.xopmc.galaxybridge.BuildConfig
import org.json.JSONObject

/** Internal-debug-only synthetic text target. No presets, clipboard, storage, network,
 * content providers or IME selection. Android's native editor owns composing/backspace. */
class TextInputQaActivity : Activity() {
    private var sequence = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!BuildConfig.DEBUG || BuildConfig.DISTRIBUTION != "internal") {
            finish()
            return
        }
        val scroll = ScrollView(this).apply { setBackgroundColor(Color.WHITE) }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(20))
        }
        scroll.addView(column, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        scroll.setOnApplyWindowInsetsListener { _, insets ->
            val safe = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            column.setPadding(dp(20) + safe.left, dp(20) + safe.top, dp(20) + safe.right, dp(20) + safe.bottom)
            insets
        }
        fun label(text: String, size: Float, height: Int): TextView = TextView(this).apply {
            this.text = text
            textSize = size
            setTextColor(Color.BLACK)
            gravity = Gravity.CENTER_VERTICAL
            column.addView(this, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(height)))
        }
        label("Galaxy Bridge text input QA", 20f, 44)
        label("Synthetic text only. Clear, type through the Mac mirror, then press Enter or Submit.", 13f, 44)
        val input = EditText(this).apply {
            id = View.generateViewId()
            contentDescription = "QA text input"
            hint = "Type synthetic text"
            textSize = 20f
            setTextColor(Color.BLACK)
            setHintTextColor(Color.DKGRAY)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            setSingleLine(true)
            imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            isSaveEnabled = false // Each activity instance begins empty; never restore prior text.
        }
        column.addView(input, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(64)))
        column.addView(View(this), LinearLayout.LayoutParams(1, dp(12)))
        val buttons = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        column.addView(buttons, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56)))
        val clear = Button(this).apply { text = "Clear"; contentDescription = "Clear input" }
        val submit = Button(this).apply { text = "Submit"; contentDescription = "Submit input" }
        buttons.addView(clear, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        buttons.addView(View(this), LinearLayout.LayoutParams(dp(12), 1))
        buttons.addView(submit, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        column.addView(View(this), LinearLayout.LayoutParams(1, dp(20)))
        val status = label("Ready — input is empty", 14f, 28).apply { contentDescription = "QA status" }
        label("Submitted exact text", 16f, 28)
        val result = TextView(this).apply {
            textSize = 20f
            setTextColor(Color.BLACK)
            minHeight = dp(72)
            isSaveEnabled = false
            contentDescription = "Submitted exact text"
        }
        column.addView(result, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        label("Submitted Unicode code points", 14f, 28)
        val unicode = TextView(this).apply {
            textSize = 13f
            setTextColor(Color.DKGRAY)
            isSaveEnabled = false
            contentDescription = "Submitted Unicode code points"
        }
        column.addView(unicode, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        fun submitExact(trigger: String) {
            val exact = input.text.toString() // No trim, normalization, case conversion or autofill.
            sequence += 1
            val points = exact.codePoints().toArray()
            result.text = exact
            unicode.text = points.joinToString(" ") { "U+%04X".format(it) }
            status.text = "Submitted #$sequence — UTF-16 ${exact.length}, code points ${points.size}"
            Log.i(LOG_TAG, JSONObject().put("event", "submit").put("sequence", sequence)
                .put("trigger", trigger).put("text", exact).put("utf16_units", exact.length)
                .put("code_points", unicode.text.toString()).toString())
        }
        clear.setOnClickListener {
            // Synchronous on the main looper: a following insert cannot overtake a posted clear.
            input.text.clear()
            input.setSelection(0)
            input.requestFocus()
            sequence += 1
            result.text = ""
            unicode.text = ""
            status.text = "Cleared #$sequence — input focused"
            Log.i(LOG_TAG, JSONObject().put("event", "clear").put("sequence", sequence)
                .put("utf16_units", input.text.length).put("input_focused", input.hasFocus()).toString())
        }
        submit.setOnClickListener { submitExact("button") }
        input.setOnEditorActionListener { _, action, event ->
            if (event?.keyCode == KeyEvent.KEYCODE_ENTER) {
                if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0 && !event.isCanceled) submitExact("enter")
                true // Consume both edges, recording a physical Enter only once.
            } else if (event == null && action in setOf(EditorInfo.IME_ACTION_DONE, EditorInfo.IME_ACTION_GO, EditorInfo.IME_ACTION_SEND)) {
                submitExact("ime_action")
                true
            } else false
        }
        setContentView(scroll)
        input.requestFocus()
        // Deliberately do not show/hide or select an IME. The host controls only mirror input.
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density + 0.5f).toInt()
    companion object { const val LOG_TAG = "GBTextInputQA" }
}

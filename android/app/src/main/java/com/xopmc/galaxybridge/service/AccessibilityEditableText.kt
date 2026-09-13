package com.xopmc.galaxybridge.service

internal object AccessibilityEditableText {
    fun current(text: String, isShowingHintText: Boolean): String =
        if (isShowingHintText) "" else text
}

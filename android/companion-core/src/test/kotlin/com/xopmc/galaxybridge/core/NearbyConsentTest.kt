package com.xopmc.galaxybridge.core

import org.junit.Assert.*
import org.junit.Test

class NearbyConsentTest {
    private fun machine() = NearbyConsent()
    @Test fun explicitVisibleConsentIsRequiredAndPollingCannotApprove() {
        val m=machine()
        assertEquals(NearbyConsent.Decision.UNAVAILABLE,m.request("a","Mac","123456",0))
        m.setVisible(true)
        assertEquals(NearbyConsent.Decision.PENDING,m.request("a","Mac","123456",0))
        repeat(10) { assertEquals(NearbyConsent.Decision.PENDING,m.request("a","Mac","123456",100)) }
        assertFalse(m.answer("wrong",true,100))
        assertTrue(m.answer("a",true,100))
        assertEquals(NearbyConsent.Decision.APPROVED,m.request("a","Mac","123456",200))
        assertEquals(NearbyConsent.Decision.BUSY,m.request("b","Other","654321",200))
    }
    @Test fun rejectionExpiryBackgroundAndRetirementCannotBeReplayed() {
        val m=machine();m.setVisible(true)
        m.request("a","Mac","123456",0);assertTrue(m.answer("a",false,1))
        assertEquals(NearbyConsent.Decision.REJECTED,m.request("a","Mac","123456",2))
        m.retire("a",3)
        assertEquals(NearbyConsent.Decision.BUSY,m.request("b","Mac","123456",4))
        assertEquals(NearbyConsent.Decision.PENDING,m.request("b","Mac","123456",60_004))
        assertFalse(m.answer("b",true,120_005))
        assertEquals(NearbyConsent.Decision.BUSY,m.request("b","Mac","123456",120_005))
        m.retire("b",120_006)
        m.request("c","Mac","123456",180_007);m.setVisible(false)
        assertEquals(NearbyConsent.Decision.REJECTED,m.request("c","Mac","123456",180_008))
    }
    @Test fun requestIdentityIsImmutableAndNamesCannotInjectControls() {
        val m=machine();m.setVisible(true)
        m.request("a","  Mac\n\u202Ename  ","123456",0)
        assertEquals("Macname",m.pending?.name)
        assertEquals(NearbyConsent.Decision.REJECTED,m.request("a","Changed","123456",1))
        assertEquals(NearbyConsent.Decision.REJECTED,m.request("a","Macname","654321",2))
        assertFalse(m.answer("a",true,3))
    }
    @Test fun silentOpenConnectionCannotKeepExpiredPromptBusyForever() {
        val m=machine();m.setVisible(true)
        m.request("attacker","Mac","123456",0)
        m.expire(60_000)
        assertNull(m.pending)
        assertFalse(m.answer("attacker",true,60_001))
        assertEquals(NearbyConsent.Decision.BUSY,m.request("legitimate","Mac","654321",60_001))
        assertEquals(NearbyConsent.Decision.PENDING,m.request("legitimate","Mac","654321",120_001))
        assertEquals("legitimate",m.pending?.id)
    }
    @Test fun contextCommitmentMatchesTheMacVectorAndBindsNameIdentityAndSecret() {
        val token=ByteArray(32){7};val identity=ByteArray(65){4}
        val expected="4742436f6e7330313990a734dc6ff958d7e887d0b51ef5359dcd13ed5e8b1ec6"
        val context=NearbyConsent.context(token,identity,"Mac")
        assertEquals(expected,context.joinToString(""){"%02x".format(it)})
        assertTrue(NearbyConsent.isContext(context))
        assertFalse(context.contentEquals(NearbyConsent.context(token,identity,"Other")))
        assertFalse(context.contentEquals(NearbyConsent.context(ByteArray(32){8},identity,"Mac")))
        assertFalse(NearbyConsent.isContext(ByteArray(32)))
    }
    @Test fun comparisonBindsBothSignedHellosAndExactRequest() {
        val fields=arrayOf("mac".toByteArray(),"phone".toByteArray(),"request".toByteArray())
        assertEquals("203337",NearbyConsent.comparison(*fields))
        assertNotEquals(NearbyConsent.comparison(*fields),NearbyConsent.comparison(fields[1],fields[0],fields[2]))
        assertNotEquals(NearbyConsent.comparison(*fields),NearbyConsent.comparison(fields[0],fields[1],"other".toByteArray()))
    }
}

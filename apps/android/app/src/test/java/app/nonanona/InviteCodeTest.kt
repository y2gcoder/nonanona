package app.nonanona

import app.nonanona.feature.trip.InviteCode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class InviteCodeTest {
    @Test
    fun parsesInviteLink() {
        assertEquals(InviteCode("SYNTHINVITE01"), InviteCode.fromLink("nonanona://invite/SYNTHINVITE01"))
        assertEquals(InviteCode("SYNTHINVITE01"), InviteCode.fromLink("nonanona://invite/SYNTHINVITE01/?from=chat"))
    }

    @Test
    fun rejectsOtherLinks() {
        assertNull(InviteCode.fromLink("https://example.com/invite/SYNTHINVITE01"))
        assertNull(InviteCode.fromLink("nonanona://invite/short"))
        assertNull(InviteCode.fromLink("nonanona://invite/has space in it"))
        assertNull(InviteCode.fromLink("nonanona://invite/../../etc"))
    }
}

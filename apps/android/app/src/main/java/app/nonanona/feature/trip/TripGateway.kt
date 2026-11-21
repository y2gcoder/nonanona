package app.nonanona.feature.trip

@JvmInline
value class InviteCode(
    val value: String,
) {
    companion object {
        private val pattern = Regex("[A-Za-z0-9_-]{8,64}")

        /** `nonanona://invite/<code>` 링크에서 초대 코드를 꺼낸다. 형식이 맞지 않으면 null. */
        fun fromLink(link: String): InviteCode? {
            val prefix = "nonanona://invite/"
            if (!link.startsWith(prefix)) return null
            val code =
                link
                    .removePrefix(prefix)
                    .substringBefore('?')
                    .substringBefore('#')
                    .trimEnd('/')
            return if (pattern.matches(code)) InviteCode(code) else null
        }
    }
}

@JvmInline
value class TripId(
    val value: String,
)

data class TripMember(
    val displayName: String,
    val isHost: Boolean,
    val isMe: Boolean,
)

data class TripRoom(
    val id: TripId,
    val name: String,
    val members: List<TripMember>,
)

class TripException(
    message: String,
) : Exception(message)

/**
 * 여행방 데이터 경계. 첫 슬라이스는 초대 수락만 정의한다. 서버 SDK 호출은 구현체 안에 둔다(ADR-0003).
 * 호출자는 로그인한 뒤에 부른다. 구현체는 인증 경계가 가진 세션으로 요청한다.
 */
interface TripGateway {
    suspend fun acceptInvite(code: InviteCode): TripRoom
}

/** release 빌드의 기본 구현체. 서버를 연결하기 전까지 어떤 초대도 수락하지 않는다. */
object UnavailableTripGateway : TripGateway {
    override suspend fun acceptInvite(code: InviteCode): TripRoom = throw TripException("trip service is not connected")
}

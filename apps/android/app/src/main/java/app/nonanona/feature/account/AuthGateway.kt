package app.nonanona.feature.account

/** 노나노나 계정 ID. 여행방·증빙·정산은 로그인 제공자의 이메일이 아니라 이 ID에 연결한다(ADR-0002). */
@JvmInline
value class AccountId(
    val value: String,
)

data class AccountSession(
    val accountId: AccountId,
    val displayName: String,
)

/** Android는 Google 로그인만 제공한다(ADR-0002). */
enum class SignInProvider { Google, }

class SignInException(
    message: String,
) : Exception(message)

/**
 * 인증 세션 경계. 화면과 기능은 이 타입만 쓰고, 로그인 SDK와 서버 호출은 구현체 안에 둔다(ADR-0003).
 * 구현체는 앱 시작 지점(AppGraph)에서 연결한다.
 */
interface AuthGateway {
    /** 로그인 화면에 보여 줄 제공자. 비어 있으면 로그인할 수 없는 상태로 보여 준다. */
    val providers: List<SignInProvider>

    /** 테스트 구현체만 값을 준다. 화면은 이 문구를 그대로 보여 준다. */
    val testOnlyNotice: String?

    suspend fun restoreSession(): AccountSession?

    suspend fun signIn(provider: SignInProvider): AccountSession
}

/** release 빌드의 기본 구현체. 실제 로그인을 연결하기 전까지 아무것도 성공시키지 않는다. */
object UnavailableAuthGateway : AuthGateway {
    override val providers: List<SignInProvider> = emptyList()
    override val testOnlyNotice: String? = null

    override suspend fun restoreSession(): AccountSession? = null

    override suspend fun signIn(provider: SignInProvider): AccountSession = throw SignInException("sign-in is not connected")
}

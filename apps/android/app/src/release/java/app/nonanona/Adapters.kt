package app.nonanona

import android.content.Context
import app.nonanona.feature.account.UnavailableAuthGateway
import app.nonanona.feature.trip.UnavailableTripGateway

/** release 빌드에는 테스트 구현체가 없다. 실제 로그인·서버를 연결하기 전까지 로그인할 수 없는 상태로 보인다. */
@Suppress("UNUSED_PARAMETER")
internal fun createAdapters(context: Context): Adapters = Adapters(UnavailableAuthGateway, UnavailableTripGateway)

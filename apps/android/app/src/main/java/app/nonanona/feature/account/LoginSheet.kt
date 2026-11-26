package app.nonanona.feature.account

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import app.nonanona.R
import app.nonanona.design.Spacing
import app.nonanona.design.StatusLabel
import app.nonanona.design.StatusRole
import app.nonanona.design.TextRoles
import app.nonanona.design.foldAwareOverlayPlacement

sealed interface LoginState {
    data object Hidden : LoginState

    data object Choosing : LoginState

    data object SigningIn : LoginState

    data class Failed(
        val failure: SignInFailure,
    ) : LoginState
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
fun LoginSheet(
    state: LoginState,
    providers: List<SignInProvider>,
    testOnlyNotice: String?,
    onSignIn: (SignInProvider) -> Unit,
    onDismiss: () -> Unit,
) {
    // 세로 접힘이 창을 나누면 시트를 넓은 쪽에만 둔다(시스템이 시트를 접힘에서 옮겨 주지 않는다).
    val placement = foldAwareOverlayPlacement()
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        modifier = placement?.let { Modifier.absoluteOffset(x = it.offsetX) } ?: Modifier,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        sheetMaxWidth = placement?.maxWidth ?: BottomSheetDefaults.SheetMaxWidth,
    ) {
        Column(
            modifier =
                Modifier
                    .semantics { testTagsAsResourceId = true }
                    .testTag("login_sheet")
                    // 낮은 창(가로, 큰 글자)에서도 모든 버튼에 스크롤로 닿는다.
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = Spacing.m)
                    .padding(bottom = Spacing.l),
            verticalArrangement = Arrangement.spacedBy(Spacing.m),
        ) {
            Text(stringResource(R.string.login_title), style = MaterialTheme.typography.headlineSmall)
            Text(stringResource(R.string.login_body), style = TextRoles.body)
            testOnlyNotice?.let { StatusLabel(it, StatusRole.Neutral, Modifier.testTag("login_test_notice")) }
            if (providers.isEmpty()) {
                Text(
                    stringResource(R.string.login_unavailable),
                    style = TextRoles.body,
                    modifier = Modifier.testTag("login_unavailable"),
                )
            }
            providers.forEach { provider ->
                OutlinedButton(
                    onClick = { onSignIn(provider) },
                    enabled = state != LoginState.SigningIn,
                    modifier = Modifier.fillMaxWidth().testTag("login_${provider.name.lowercase()}"),
                ) {
                    Text(
                        when (provider) {
                            SignInProvider.Google -> stringResource(R.string.login_google)
                        },
                    )
                }
            }
            when (state) {
                LoginState.SigningIn -> {
                    Row(horizontalArrangement = Arrangement.spacedBy(Spacing.s), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                        Text(stringResource(R.string.login_in_progress), style = TextRoles.supporting)
                    }
                }

                is LoginState.Failed -> {
                    // 다시 시도는 같은 제공자 버튼으로 한다. 제공자 원문은 보여 주지 않는다.
                    Text(
                        stringResource(state.failure.messageRes()),
                        style = TextRoles.supporting,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.testTag("login_failed"),
                    )
                }

                LoginState.Hidden, LoginState.Choosing -> {}
            }
        }
    }
}

private fun SignInFailure.messageRes(): Int =
    when (this) {
        SignInFailure.Network -> R.string.failure_network
        SignInFailure.Unavailable -> R.string.login_failure_unavailable
        SignInFailure.Cancelled, SignInFailure.Unknown -> R.string.login_failed
    }

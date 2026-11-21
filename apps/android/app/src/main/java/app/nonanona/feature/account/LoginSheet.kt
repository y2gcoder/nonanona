package app.nonanona.feature.account

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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

enum class LoginState { Hidden, Choosing, SigningIn, Failed }

@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
fun LoginSheet(
    state: LoginState,
    providers: List<SignInProvider>,
    testOnlyNotice: String?,
    onSignIn: (SignInProvider) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(
            modifier =
                Modifier
                    .semantics { testTagsAsResourceId = true }
                    .testTag("login_sheet")
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

                LoginState.Failed -> {
                    Text(
                        stringResource(R.string.login_failed),
                        style = TextRoles.supporting,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.testTag("login_failed"),
                    )
                }

                LoginState.Hidden, LoginState.Choosing -> {
                    Unit
                }
            }
        }
    }
}

/*
 * Copyright (C) Fabian Müller <fmueller@owncloud.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */

#include <QApplication>
#include <QClipboard>

#include "gui/application.h"
#include "jobs/webfingeruserinfojobfactory.h"
#include "oauthcredentialssetupwizardstate.h"
#include "theme.h"

namespace OCC::Wizard {

OAuthCredentialsSetupWizardState::OAuthCredentialsSetupWizardState(SetupWizardContext *context)
    : AbstractSetupWizardState(context)
{
    const auto authServerUrl = [this]() {
        auto authServerUrl = _context->accountBuilder().webFingerAuthenticationServerUrl();
        if (!authServerUrl.isEmpty()) {
            return authServerUrl;
        }
        return _context->accountBuilder().serverUrl();
    }();

    auto oAuthCredentialsPage = new OAuthCredentialsSetupWizardPage(authServerUrl);
    _page = oAuthCredentialsPage;

    auto oAuth = new OAuth(authServerUrl, _context->accountBuilder().legacyWebFingerUsername(), _context->accessManager(), {}, this);

    connect(oAuth, &OAuth::result, this, [this, oAuthCredentialsPage](OAuth::Result result, const QString &token, const QString &refreshToken) {
        // the button may not be clicked anymore, since the server has been shut down right before this signal was emitted by the OAuth instance
        oAuthCredentialsPage->setButtonsEnabled(false);

        _context->window()->slotStartTransition();

        // bring window up top again, as the browser may have been raised in front of it
        _context->window()->raise();

        auto finish = [=]() {
            switch (result) {
            case OAuth::Result::LoggedIn: {
                _context->accountBuilder().setAuthenticationStrategy(new OAuth2AuthenticationStrategy(token, refreshToken));
                Q_EMIT evaluationSuccessful();
                break;
            }
            case OAuth::Result::Error: {
                Q_EMIT evaluationFailed(tr("Error while trying to log in to OAuth2-enabled server."));
                break;
            }
            case OAuth::Result::NotSupported: {
                // should never happen
                Q_EMIT evaluationFailed(tr("Server reports that OAuth2 is not supported."));
                break;
            }
            }
        };

        // we run this job here so that it runs during the transition state
        // sure, it's not the cleanest ever approach, but currently it's good enough
        if (!_context->accountBuilder().webFingerAuthenticationServerUrl().isEmpty()) {
            auto *job = Jobs::WebFingerInstanceLookupJobFactory(_context->accessManager(), token).startJob(_context->accountBuilder().serverUrl(), this);

            connect(job, &CoreJob::finished, this, [=]() {
                if (!job->success()) {
                    Q_EMIT evaluationFailed(QStringLiteral("Failed to look up instances: %1").arg(job->errorMessage()));
                } else {
                    const auto instanceUrls = qvariant_cast<QVector<QUrl>>(job->result());

                    if (instanceUrls.isEmpty()) {
                        Q_EMIT evaluationFailed(QStringLiteral("Server returned empty list of instances"));
                    } else {
                        _context->accountBuilder().setWebFingerInstances(instanceUrls);
                    }
                }

                finish();
            });
        } else {
            finish();
        }
    });

    connect(oAuthCredentialsPage, &OAuthCredentialsSetupWizardPage::openBrowserButtonPushed, this, [oAuth]() {
        oAuth->openBrowser();
    });

    oAuthCredentialsPage->setButtonsEnabled(false);
    connect(oAuth, &OAuth::authorisationLinkChanged, this, [oAuthCredentialsPage]() {
        oAuthCredentialsPage->setButtonsEnabled(true);
    });

    connect(oAuth, &OAuth::dynamicRegistrationDataReceived, this, [this](const QVariantMap &dynamicRegistrationData) {
        _context->accountBuilder().setDynamicRegistrationData(dynamicRegistrationData);
    });

    connect(oAuthCredentialsPage, &OAuthCredentialsSetupWizardPage::copyUrlToClipboardButtonPushed, this, [oAuth]() {
        const auto link = oAuth->authorisationLink();
        Q_ASSERT(!link.isEmpty());
        qApp->clipboard()->setText(link.toString());
    });

    // the implementation moves to the next state automatically once ready, no user interaction needed
    _context->window()->disableNextButton();

    oAuth->startAuthentication();
}

SetupWizardState OAuthCredentialsSetupWizardState::state() const
{
    return SetupWizardState::CredentialsState;
}

void OAuthCredentialsSetupWizardState::evaluatePage()
{
    // the next button is disabled anyway, since moving forward is controlled by the OAuth object signal handlers
    // therefore, this method should never ever be called
    Q_UNREACHABLE();
}

} // OCC::Wizard

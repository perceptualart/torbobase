// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
import Foundation

/// Legal text embedded in the binary — no external file dependencies
enum Legal {

    static let eulaAcceptedKey = "torboEULAAccepted"
    static let eulaVersionKey = "torboEULAVersion"
    static let currentEULAVersion = "2026.02.05"

    static var eulaAccepted: Bool {
        get {
            UserDefaults.standard.bool(forKey: eulaAcceptedKey) &&
            UserDefaults.standard.string(forKey: eulaVersionKey) == currentEULAVersion
        }
        set {
            UserDefaults.standard.set(newValue, forKey: eulaAcceptedKey)
            if newValue { UserDefaults.standard.set(currentEULAVersion, forKey: eulaVersionKey) }
        }
    }

    static let eulaText = """
    TORBO BASE — END USER LICENSE AGREEMENT

    Licensor: Perceptual Art LLC

    BY USING THIS SOFTWARE, YOU AGREE TO THE FOLLOWING TERMS:

    1. LICENSE — You are granted a limited, non-exclusive, non-transferable license \
    to use Torbo Base on devices you own or control.

    2. YOUR RESPONSIBILITY — You are solely responsible for all AI models on your \
    system, all outputs they generate, all commands executed through this gateway, \
    and the access level you configure.

    3. NO WARRANTY — This software is provided "AS IS" without warranty of any kind. \
    We do not warrant that the software will be secure, uninterrupted, or error-free. \
    No security software can guarantee absolute protection.

    4. LIMITATION OF LIABILITY — In no event shall Perceptual Art LLC be liable for \
    any indirect, incidental, special, consequential, or exemplary damages, including \
    loss of data, unauthorized system access, or actions taken by AI models.

    5. AI DISCLAIMER — We are not the provider of any AI model accessed through this \
    software. AI models may behave unpredictably. You use them at your own risk.

    6. INDEMNIFICATION — You agree to hold Perceptual Art LLC harmless from any claims \
    arising from your use of this software.

    7. PRIVACY — This software collects zero data. Everything stays on your device.

    8. GOVERNING LAW — This agreement is governed by the laws of New York State, USA.

    Full EULA and Privacy Policy: https://torbobase.ai/legal

    © 2026 Perceptual Art LLC. All rights reserved.
    """

    static let privacySummary = """
    Torbo Base collects ZERO data. No telemetry, no analytics, no crash reports, \
    no usage tracking. Everything runs locally on your device. We operate no servers \
    and have no access to your data, conversations, files, or activity.
    """

    static let aboutText = """
    Torbo Base v2.0.0
    Local AI Gateway with Access Control

    © 2026 Perceptual Art LLC
    All rights reserved.

    This software is provided under a proprietary license.
    See EULA and Privacy Policy at https://torbobase.ai/legal
    """
}

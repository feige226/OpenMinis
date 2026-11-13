# Trae and Raccoon providers

OpenMinis adapts the Trae, Trae CN and Raccoon account protocols from the supplied Apelin provider reference source. These integrations use account sign-in and provider-specific wire formats. They require an account with access to the selected models; signing in does not grant a subscription or additional quota.

| Entry | Account region | Default chat origin | Wire format |
| --- | --- | --- | --- |
| Trae | International | `https://core-normal.trae.ai` | Trae `llm_utils_chat`, custom SSE |
| Trae CN | China | `https://trae-api-cn.mchost.guru` | Trae `llm_utils_chat`, custom SSE |
| Raccoon | Raccoon Work | `https://xiaohuanxiong.com` | Raccoon OpenAI-compatible chat/SSE |

The Trae CN chat origin above is the **third-party gateway supplied by the reference implementation**, not a `trae.cn` domain. It receives the account token and conversation payload when selected. Review that endpoint before signing in. An account's authorization host is separate from its chat origin; changing one does not automatically change the other. Custom endpoints must implement the same provider-specific protocol.

## Sign-in and model discovery

Add an instance from Settings → Providers, choose the appropriate entry, and use its account sign-in action. Trae and Trae CN use different authorization profiles, gateways and saved credentials. Use the matching account region. The browser returns to a temporary listener bound to the device's loopback interface. Keep OpenMinis running during sign-in.

Trae discovers the international login host, uses PKCE, and exchanges the authorization code with a device public key. Raccoon exchanges its authorization code and retains the organization identity needed for subsequent requests. Access tokens and rotated refresh tokens belong to the provider instance; sign-out removes that instance's credentials. Model discovery uses the same account as chat.

Trae obtains model configuration from `/api/ide/v1/get_detail_param`, preserving the function associated with each model. Raccoon obtains its catalog from `/api/web/llm/v2/model_catalog`. A fallback list cannot establish that a model is available to the signed-in account. Provider model names, availability and account requirements can change independently of OpenMinis.

## Conversation protocol

Trae chat uses `/api/agent/v3/llm_utils_chat`. Messages contain text blocks, assistant tool calls use the `function_call` array, and tool schemas encode `function.parameters` as a JSON string. The stream's `output`, `token_usage`, `done` and `error` events are translated into OpenMinis text, reasoning, usage and local tool calls. Tools run through the OpenMinis agent loop. Trae's hosted `chat_sessions` tool runtime is not used.

Raccoon chat uses `/api/web/llm/v2/chat/completions`, standard OpenAI-style messages, tools and SSE deltas, plus its organization header. Raccoon limits requested output to 65,536 tokens. Its reference reasoning switch is the nested `extra_body.thinking.type = "enabled"`; it does not establish independently selectable low/medium/high budgets or guarantee that omitting the switch disables server-default reasoning.

Treat unsupported attachments conservatively. Trae's reference wire conversion only supports text. Model names alone are not evidence of vision, audio or image-generation support.

## Validation and provenance

The reference package targets `owngoal-dev/Apelin` commit `760b93e`; OpenMinis has a different provider architecture, so its source patches are not applied directly. No Apelin runtime or `KWWKAI` dependency is added.

The integration and its GitHub Actions workflow target **iOS only**. The `iOS provider build` workflow builds the native dependencies, checks the Swift sources, and compiles an unsigned iOS device app with Xcode on a macOS runner. A successful run uploads `OpenMinis-unsigned-iOS` containing an unsigned IPA; installation requires signing with an appropriate certificate and provisioning profile. Build logs and the Xcode result bundle are uploaded separately.

Development in Minis iSH permits resource/static checks but does not provide Xcode or the iOS SDK. Static checks do **not** establish a successful application build or a working provider account. GitHub Actions supplies the build environment. Before release, also verify real sign-in, token refresh, model discovery, streaming, cancellation and a complete local tool-call round trip on an iOS device. Never include access tokens, refresh tokens, authorization codes or complete callback URLs in test logs or bug reports.

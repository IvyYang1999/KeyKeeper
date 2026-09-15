import AppKit
import SwiftUI
import KeyKeeperCore

/// Brand marks for the provider templates, so a Stripe key looks like Stripe at a glance.
///
/// yyt 2026-09-15: "全都是小字，阅读起来很困难". Preserve official multicolour artwork where
/// colour is part of the identity; tint monochrome artwork with the provider colour in recognition-
/// critical prompts. Every bundled asset records its provider-owned source. If there is no suitable
/// provider-sourced asset, use a coloured lettermark — never invent a generic product icon.
enum ProviderMarks {
    struct Mark {
        let svgBody: String?
        let darkSVGBody: String?
        let pngBase64: String?
        let systemSymbolName: String?
        let brandHex: String
        let source: String
        let viewBox: String
        let isTemplate: Bool

        init(path: String, brandHex: String, source: String, viewBox: String = "0 0 24 24") {
            self.svgBody = #"<path d="\#(path)"/>"#
            self.darkSVGBody = nil
            self.pngBase64 = nil
            self.systemSymbolName = nil
            self.brandHex = brandHex
            self.source = source
            self.viewBox = viewBox
            self.isTemplate = true
        }

        init(svgBody: String, darkSVGBody: String? = nil, brandHex: String, source: String,
             viewBox: String, isTemplate: Bool = false) {
            self.svgBody = svgBody
            self.darkSVGBody = darkSVGBody
            self.pngBase64 = nil
            self.systemSymbolName = nil
            self.brandHex = brandHex
            self.source = source
            self.viewBox = viewBox
            self.isTemplate = isTemplate
        }

        init(pngBase64: String, brandHex: String, source: String) {
            self.svgBody = nil
            self.darkSVGBody = nil
            self.pngBase64 = pngBase64
            self.systemSymbolName = nil
            self.brandHex = brandHex
            self.source = source
            self.viewBox = ""
            self.isTemplate = false
        }

        init(systemSymbolName: String, brandHex: String, source: String) {
            self.svgBody = nil
            self.darkSVGBody = nil
            self.pngBase64 = nil
            self.systemSymbolName = systemSymbolName
            self.brandHex = brandHex
            self.source = source
            self.viewBox = ""
            self.isTemplate = true
        }
    }

    /// Exact single-graphic artwork from provider-owned sources. Kept separate from the generated
    /// normalized set so original geometry and multicolour treatment stay untouched.
    private static let directOfficialMarks: [String: Mark] = [
        "openai": Mark(
            path: "M508.749 317.399C516.777 287.314 508.991 253.884 485.389 230.282C461.788 206.681 428.36 198.895 398.273 206.923C376.231 184.928 343.39 174.956 311.148 183.596C278.906 192.234 255.45 217.292 247.36 247.361C217.291 255.451 192.233 278.91 183.595 311.149C174.957 343.391 184.927 376.232 206.924 398.274C198.896 428.359 206.683 461.789 230.284 485.391C253.885 508.992 287.313 516.779 317.401 508.75C339.442 530.745 372.286 540.717 404.525 532.079C436.767 523.441 460.223 498.384 468.313 468.315C498.383 460.224 523.44 436.766 532.078 404.526C540.716 372.285 530.747 339.443 508.749 317.402V317.399ZM470.899 244.776C486.892 260.77 493.488 282.601 490.687 303.412L415.577 260.046C412.411 258.218 408.509 258.218 405.345 260.046L317.401 310.82V277.526C317.401 275.191 318.652 273.005 320.676 271.837L387.644 233.174C414.178 218.353 448.346 222.223 470.901 244.776H470.899ZM357.837 311.144L398.275 334.491V381.185L357.837 404.532L317.398 381.185V334.491L357.837 311.144ZM264.776 269.693C265.207 239.305 285.644 211.649 316.453 203.393C338.3 197.54 360.505 202.744 377.127 215.573L302.014 258.937C298.848 260.764 296.898 264.144 296.898 267.798V369.346L268.065 352.699C266.043 351.531 264.776 349.353 264.776 347.017V269.691V269.693ZM203.391 316.454C209.244 294.608 224.854 277.978 244.276 269.999V356.73C244.276 360.384 246.226 363.763 249.392 365.591L337.337 416.365L308.503 433.013C306.481 434.181 303.961 434.188 301.939 433.02L234.971 394.357C208.868 378.789 195.138 347.261 203.391 316.454ZM244.775 470.9C228.781 454.906 222.186 433.075 224.986 412.264L300.096 455.63C303.263 457.457 307.164 457.457 310.328 455.63L398.273 404.856V438.149C398.273 440.485 397.022 442.671 394.997 443.839L328.029 482.502C301.495 497.322 267.327 493.452 244.772 470.9H244.775ZM450.897 445.982C450.466 476.371 430.029 504.027 399.22 512.283C377.373 518.136 355.168 512.932 338.547 500.102L413.659 456.738C416.826 454.911 418.775 451.532 418.775 447.877V346.329L447.609 362.977C449.631 364.145 450.897 366.323 450.897 368.659V445.985V445.982ZM512.282 399.221C506.429 421.068 490.819 437.697 471.397 445.676V358.946C471.397 355.292 469.448 351.912 466.281 350.085L378.336 299.311L407.17 282.663C409.192 281.495 411.712 281.487 413.734 282.655L480.702 321.318C506.805 336.887 520.536 368.415 512.282 399.221Z",
            brandHex: "000000",
            source: "https://cdn.openai.com/brand/openai-logos.zip",
            // The official file includes a 180 px presentation margin. The surrounding provider
            // tile already supplies safe area, so crop only that transparent margin for legibility.
            viewBox: "160 160 396 396"),
        "feishu": Mark(
            pngBase64: ProviderOfficialImageData.feishuPNGBase64,
            brandHex: "3370FF",
            source: "https://p1-hera.feishucdn.com/tos-cn-i-jbbdkfciu3/84a9f036fe2b44f99b899fff4beeb963~tplv-jbbdkfciu3-image:100:100.image"),
        "zhipu": Mark(
            svgBody: ##"<path d="M24.51,28.51H5.49c-2.21,0-4-1.79-4-4V5.49c0-2.21,1.79-4,4-4h19.03c2.21,0,4,1.79,4,4v19.03C28.51,26.72,26.72,28.51,24.51,28.51z" fill="#2D2D2D" stroke="#FFFFFF" stroke-width="0.6317"/><path d="M15.47,7.1l-1.3,1.85c-0.2,0.29-0.54,0.47-0.9,0.47h-7.1V7.09C6.16,7.1,15.47,7.1,15.47,7.1z" fill="#FFFFFF"/><polygon points="24.3,7.1 13.14,22.91 5.7,22.91 16.86,7.1" fill="#FFFFFF"/><path d="M14.53,22.91l1.31-1.86c0.2-0.29,0.54-0.47,0.9-0.47h7.09v2.33H14.53z" fill="#FFFFFF"/>"##,
            brandHex: "126EF6",
            source: "https://z-cdn.chatglm.cn/z-ai/static/logo.svg",
            viewBox: "0 0 30 30"),
        "kimi": Mark(
            svgBody: ##"<path d="M21.7202 0.939941C22.9502 0.939941 23.9502 1.93994 23.9502 3.16994C23.9502 4.39994 22.9502 5.39994 21.7202 5.39994H19.7502C19.6002 5.39994 19.4902 5.27994 19.4902 5.13994V3.16994C19.4902 1.93994 20.4902 0.939941 21.7202 0.939941Z" fill="#1783FF"/><path d="M9.39 13.9501L17.82 5.59012C17.98 5.43012 17.89 5.12012 17.68 5.12012H13.14C13.14 5.12012 13.04 5.14012 13 5.18012L3.92 14.1901C3.78 14.3301 3.57 14.2101 3.57 13.9801V5.39012C3.57 5.24012 3.47 5.12012 3.35 5.12012H0.219999C0.0999993 5.12012 0 5.24012 0 5.39012V23.9201C0 24.0701 0.0999993 24.1901 0.219999 24.1901H3.35C3.47 24.1901 3.57 24.0701 3.57 23.9201V20.1401C3.57 20.0601 3.6 19.9801 3.65 19.9301L6.47 17.1401C6.54 17.0701 6.63 17.0601 6.71 17.1101L14.24 22.6501C15.47 23.4801 16.85 23.9901 18.25 24.1401C18.37 24.1501 18.48 24.0301 18.48 23.8701V20.3101C18.48 20.1701 18.4 20.0601 18.29 20.0501C17.47 19.9201 16.66 19.6001 15.94 19.1101L9.42 14.3901C9.28 14.3001 9.27 14.0701 9.39 13.9501Z" fill="#000000"/>"##,
            darkSVGBody: ##"<path d="M21.7202 0.939941C22.9502 0.939941 23.9502 1.93994 23.9502 3.16994C23.9502 4.39994 22.9502 5.39994 21.7202 5.39994H19.7502C19.6002 5.39994 19.4902 5.27994 19.4902 5.13994V3.16994C19.4902 1.93994 20.4902 0.939941 21.7202 0.939941Z" fill="#1783FF"/><path d="M9.39 13.9501L17.82 5.59012C17.98 5.43012 17.89 5.12012 17.68 5.12012H13.14C13.14 5.12012 13.04 5.14012 13 5.18012L3.92 14.1901C3.78 14.3301 3.57 14.2101 3.57 13.9801V5.39012C3.57 5.24012 3.47 5.12012 3.35 5.12012H0.219999C0.0999993 5.12012 0 5.24012 0 5.39012V23.9201C0 24.0701 0.0999993 24.1901 0.219999 24.1901H3.35C3.47 24.1901 3.57 24.0701 3.57 23.9201V20.1401C3.57 20.0601 3.6 19.9801 3.65 19.9301L6.47 17.1401C6.54 17.0701 6.63 17.0601 6.71 17.1101L14.24 22.6501C15.47 23.4801 16.85 23.9901 18.25 24.1401C18.37 24.1501 18.48 24.0301 18.48 23.8701V20.3101C18.48 20.1701 18.4 20.0601 18.29 20.0501C17.47 19.9201 16.66 19.6001 15.94 19.1101L9.42 14.3901C9.28 14.3001 9.27 14.0701 9.39 13.9501Z" fill="#FFFFFF"/>"##,
            brandHex: "1783FF",
            source: "https://moonshotai.github.io/Branding-Guide/scenarios/04-k-only/k-only-light.svg",
            viewBox: "0 0 24 25"),
        "siliconflow": Mark(
            path: "M161.05,22L99.21,22C95.79,22,93.03,24.77,93.03,28.18L93.03,46.730000000000004C93.03,50.15,90.26,52.91,86.85,52.91L31.18,52.91C27.759999999999998,52.91,25,55.68,25,59.09L25,83.83C25,87.25,27.77,90.01,31.18,90.01L93.02,90.01C96.44,90.01,99.2,87.24,99.2,83.83L99.2,65.28C99.2,61.86,101.97,59.1,105.38,59.1L161.04,59.1C164.46,59.1,167.22,56.33,167.22,52.92L167.22,28.18C167.22,24.759999999999998,164.45,22,161.04,22L161.05,22Z",
            brandHex: "6E29F6",
            source: "https://static02.siliconflow.cn/www/cn/res/20260615/SiliconFlow_LOGO.zip",
            viewBox: "0 0 193 112"),
        "slack": Mark(
            pngBase64: ProviderOfficialImageData.slackPNGBase64,
            brandHex: "611F69",
            source: "https://a.slack-edge.com/80588/marketing/img/meta/slack_hash_256.png"),
        "app-store-connect": Mark(
            pngBase64: ProviderOfficialImageData.appStoreConnectPNGBase64,
            brandHex: "0D96F6",
            source: "https://developer.apple.com/assets/elements/icons/app-store-connect/app-store-connect-32x32_2x.png"),
        "aws": Mark(
            pngBase64: ProviderOfficialImageData.awsPNGBase64,
            brandHex: "FF9900",
            source: "https://a0.awsstatic.com/libra-css/images/site/touch-icon-iphone-114-smile.png"),
        "volcengine-ark": Mark(
            // The console asset expresses these five mountains as luminance masks over solid
            // rectangles. Direct paths are pixel-equivalent and avoid a CoreSVG mask warning.
            svgBody: ##"<path d="M0.347656 22.254H6.6917L3.81945 13.22C3.76717 13.05 3.58591 12.958 3.41859 13.0111C3.32099 13.043 3.2443 13.1208 3.21293 13.22L0.347656 22.254Z" fill="#00DCFF"/><path d="M15.7734 22.2655H23.1353L19.7576 11.6243C19.7053 11.4543 19.5241 11.3623 19.3568 11.4154C19.2592 11.4473 19.1825 11.5251 19.1511 11.6243L15.7734 22.2655Z" fill="#00DCFF"/><path d="M7.01172 22.2654H20.5922L14.1052 1.9564C14.0494 1.78648 13.8717 1.69444 13.7043 1.75108C13.6067 1.78294 13.5301 1.86082 13.4987 1.9564L7.01172 22.2654Z" fill="#006AFF"/><path d="M2.8863 22.2674H13.1657L8.32754 7.11265C8.27176 6.94273 8.09399 6.85069 7.92668 6.90733C7.82908 6.93919 7.75239 7.01707 7.72102 7.11265L2.88281 22.2674H2.8863Z" fill="#006AFF"/><path d="M5.73438 22.2673H14.4278L10.3844 9.67906C10.3286 9.50914 10.1508 9.4171 9.98349 9.47374C9.88589 9.5056 9.81269 9.58348 9.78132 9.67906L5.73786 22.2673H5.73438Z" fill="#00DCFF"/>"##,
            brandHex: "006AFF",
            source: "https://res.gcloudcache.com/volc-fe/console-ark/ark-new-main/arkIcon.svg",
            viewBox: "0 0 24 24"),
        "azure": Mark(
            svgBody: ##"<path d="M5.33492 1.37491C5.44717 1.04229 5.75909 0.818359 6.11014 0.818359H11.25L5.91513 16.6255C5.80287 16.9581 5.49095 17.182 5.13991 17.182H1.13968C0.579936 17.182 0.185466 16.6325 0.364461 16.1022L5.33492 1.37491Z" fill="url(#azure-paint0)"/><path d="M13.5517 11.4546H5.45126C5.1109 11.4546 4.94657 11.8715 5.19539 12.1037L10.4005 16.9618C10.552 17.1032 10.7515 17.1819 10.9587 17.1819H15.5453L13.5517 11.4546Z" fill="#0078D4"/><path d="M6.11014 0.818359C5.75909 0.818359 5.44717 1.04229 5.33492 1.37491L0.364461 16.1022C0.185466 16.6325 0.579936 17.182 1.13968 17.182H5.13991C5.49095 17.182 5.80287 16.9581 5.91513 16.6255L6.90327 13.6976L10.4005 16.9617C10.552 17.1032 10.7515 17.1818 10.9588 17.1818H15.5454L13.5517 11.4545H7.66032L11.25 0.818359H6.11014Z" fill="url(#azure-paint1)"/><path d="M12.665 1.37478C12.5528 1.04217 12.2409 0.818237 11.8898 0.818237H6.13629H6.16254C6.51358 0.818237 6.82551 1.04217 6.93776 1.37478L11.9082 16.1021C12.0872 16.6324 11.6927 17.1819 11.133 17.1819H11.0454H16.8603C17.42 17.1819 17.8145 16.6324 17.6355 16.1021L12.665 1.37478Z" fill="url(#azure-paint2)"/><defs><linearGradient id="azure-paint0" x1="6.07512" y1="1.38476" x2="0.738178" y2="17.1514" gradientUnits="userSpaceOnUse"><stop stop-color="#114A8B"/><stop offset="1" stop-color="#0669BC"/></linearGradient><linearGradient id="azure-paint1" x1="10.3402" y1="11.4564" x2="9.107" y2="11.8734" gradientUnits="userSpaceOnUse"><stop stop-opacity="0.3"/><stop offset="0.0711768" stop-opacity="0.2"/><stop offset="0.321031" stop-opacity="0.1"/><stop offset="0.623053" stop-opacity="0.05"/><stop offset="1" stop-opacity="0"/></linearGradient><linearGradient id="azure-paint2" x1="9.45858" y1="1.38467" x2="15.3168" y2="16.9926" gradientUnits="userSpaceOnUse"><stop stop-color="#3CCBF4"/><stop offset="1" stop-color="#2892DF"/></linearGradient></defs>"##,
            brandHex: "0078D4",
            source: "https://learn.microsoft.com/en-us/azure/architecture/icons/",
            viewBox: "0 0 18 18"),
        "telegram": Mark(
            svgBody: ##"<defs><linearGradient id="telegram-gradient" x1="50%" x2="50%" y1="0%" y2="99.258%"><stop offset="0%" stop-color="#2AABEE"/><stop offset="100%" stop-color="#229ED9"/></linearGradient></defs><g fill="none" fill-rule="evenodd"><circle cx="64" cy="64" r="64" fill="url(#telegram-gradient)" fill-rule="nonzero"/><path fill="#FFF" fill-rule="nonzero" d="M28.9700376,63.3244248 C47.6273373,55.1957357 60.0684594,49.8368063 66.2934036,47.2476366 C84.0668845,39.855031 87.7600616,38.5708563 90.1672227,38.528 C90.6966555,38.5191258 91.8804274,38.6503351 92.6472251,39.2725385 C93.294694,39.7979149 93.4728387,40.5076237 93.5580865,41.0057381 C93.6433345,41.5038525 93.7494885,42.63857 93.6651041,43.5252052 C92.7019529,53.6451182 88.5344133,78.2034783 86.4142057,89.5379542 C85.5170662,94.3339958 83.750571,95.9420841 82.0403991,96.0994568 C78.3237996,96.4414641 75.5015827,93.6432685 71.9018743,91.2836143 C66.2690414,87.5912212 63.0868492,85.2926952 57.6192095,81.6896017 C51.3004058,77.5256038 55.3966232,75.2369981 58.9976911,71.4967761 C59.9401076,70.5179421 76.3155302,55.6232293 76.6324771,54.2720454 C76.6721165,54.1030573 76.7089039,53.4731496 76.3346867,53.1405352 C75.9604695,52.8079208 75.4081573,52.921662 75.0095933,53.0121213 C74.444641,53.1403447 65.4461175,59.0880351 48.0140228,70.8551922 C45.4598218,72.6091037 43.1463059,73.4636682 41.0734751,73.4188859 C38.7883453,73.3695169 34.3926725,72.1268388 31.1249416,71.0646282 C27.1169366,69.7617838 23.931454,69.0729605 24.208838,66.8603276 C24.3533167,65.7078514 25.9403832,64.5292172 28.9700376,63.3244248 Z"/></g>"##,
            brandHex: "26A5E4",
            source: "https://telegram.org/img/t_logo.svg",
            viewBox: "0 0 128 128"),
        "posthog": Mark(
            svgBody: ##"<path fill="url(#posthog-p6)" d="M10.74 7.16 4.54.8A2.66 2.66 0 0 0 0 2.66V7.5l10.74 11.18z"/><path fill="url(#posthog-p7)" d="M9.19 28h1.55v-9.32L0 7.5v10.73z"/><path fill="url(#posthog-p8)" d="M0 25.41A2.6 2.6 0 0 0 2.58 28H9.2L0 18.23z"/><path fill="url(#posthog-p3)" d="M10.74 2.66v4.5l11.22 11.52V7.63L15.3.8a2.66 2.66 0 0 0-4.56 1.86"/><path fill="url(#posthog-p4)" d="M10.74 28h8.96l-8.96-9.32z"/><path fill="url(#posthog-p5)" d="M10.74 7.16v11.52L19.7 28h2.26v-9.32z"/><path fill="url(#posthog-p0)" d="M21.96 2.67v4.96l11.3 11.6h.02V7.75L26.63.85a2.8 2.8 0 0 0-2-.85 2.67 2.67 0 0 0-2.67 2.67"/><path fill="url(#posthog-p1)" d="M21.96 7.63v11.05L31.03 28h2.25v-8.75z"/><path fill="url(#posthog-p2)" d="M21.96 28h9.07l-9.07-9.32z"/><path fill="#111" d="M51.66 25.22A1.9 1.9 0 0 0 50 23.33l-.34-.04c-1-.13-1.94-.6-2.65-1.33L33.28 7.75V28H49a2.66 2.66 0 0 0 2.67-2.67zM39.2 23.54h-.09a1.78 1.78 0 1 1 .1 0"/><defs><linearGradient id="posthog-p0" x1="21.96" x2="33.28" y1="9.62" y2="9.62" gradientUnits="userSpaceOnUse"><stop stop-color="#ffd849"/><stop offset=".96" stop-color="#fbae01"/></linearGradient><linearGradient id="posthog-p1" x1="21.96" x2="33.28" y1="17.81" y2="17.81" gradientUnits="userSpaceOnUse"><stop stop-color="#ffb700"/><stop offset="1" stop-color="#f9aa01"/></linearGradient><linearGradient id="posthog-p2" x1="21.96" x2="31.03" y1="23.34" y2="23.34" gradientUnits="userSpaceOnUse"><stop stop-color="#ff9500"/><stop offset="1" stop-color="#f8aa00"/></linearGradient><linearGradient id="posthog-p3" x1="10.74" x2="21.96" y1="9.34" y2="9.34" gradientUnits="userSpaceOnUse"><stop stop-color="#ff651e"/><stop offset="1" stop-color="#e4400a"/></linearGradient><linearGradient id="posthog-p4" x1="10.74" x2="19.7" y1="23.34" y2="23.34" gradientUnits="userSpaceOnUse"><stop stop-color="#c42c00"/><stop offset="1" stop-color="#d63600"/></linearGradient><linearGradient id="posthog-p5" x1="10.74" x2="21.96" y1="17.58" y2="17.58" gradientUnits="userSpaceOnUse"><stop stop-color="#ef3c00"/><stop offset="1" stop-color="#d63601"/></linearGradient><linearGradient id="posthog-p6" x1="0" x2="10.74" y1="9.34" y2="9.34" gradientUnits="userSpaceOnUse"><stop stop-color="#3f80ff"/><stop offset="1" stop-color="#084fe0"/></linearGradient><linearGradient id="posthog-p7" x1="0" x2="10.74" y1="17.75" y2="17.75" gradientUnits="userSpaceOnUse"><stop stop-color="#0255ff"/><stop offset="1" stop-color="#0145d2"/></linearGradient><linearGradient id="posthog-p8" x1="0" x2="9.19" y1="23.11" y2="23.11" gradientUnits="userSpaceOnUse"><stop stop-color="#0041c6"/><stop offset="1" stop-color="#0045d0"/></linearGradient></defs>"##,
            darkSVGBody: ##"<path fill="#fff" d="M.87 19.13a.5.5 0 0 0-.87.34v5.94a2.6 2.6 0 0 0 2.59 2.58H7.8a.5.5 0 0 0 .37-.84zM.86 8.4c-.3-.32-.86-.1-.86.36v6.73q0 .2.13.34l8.81 9.68 1.8 2.06v-8.82zM4.59.82A2.67 2.67 0 0 0 0 2.68v1.93q0 .4.27.69l10.47 10.95v-9.1z"/><path fill="#fff" d="M11.36 28h7.08a.5.5 0 0 0 .36-.85l-8.05-8.4v8.8l.23.28q.16.17.38.17m-.61-11.76 8.84 9.25 2.1 2.33q.1.11.27.14V18.7L10.75 7.15zm0-13.7v1.41a2 2 0 0 0 .55 1.28L21.96 16.2V7.65L15.32.8a2.67 2.67 0 0 0-4.57 1.71z"/><path fill="#fff" d="M22.06 28h7.76a.5.5 0 0 0 .36-.86l-8.22-8.45v9.27l.09.02zM31 25.49l1.13 1.14c.32.31.85.09.85-.35v-7.3l-.49-.51L21.96 7.64v8.55zM22.52 5.73l9.62 9.89c.3.32.86.1.86-.35V7.46L26.56.82a2.67 2.67 0 0 0-4.59 1.84v1.7c0 .51.2 1 .57 1.37z"/><path fill="#fff" d="m50 23.34-.35-.05A4.5 4.5 0 0 1 47 21.97L35.56 10.1c-.3-.33-.86-.1-.86.35V27.5c0 .27.22.5.5.5h13.78c1.48 0 2.67-1.2 2.67-2.67v-.1a1.9 1.9 0 0 0-1.67-1.89zm-10.81.2a1.8 1.8 0 1 1 0-3.58 1.8 1.8 0 0 1 0 3.58"/>"##,
            brandHex: "F54E00",
            source: "https://posthog.com/handbook/brand/assets",
            viewBox: "0 0 52 28"),
        "apple-notary": Mark(
            systemSymbolName: "checkmark.seal.fill",
            brandHex: "000000",
            source: "https://developer.apple.com/design/human-interface-guidelines/sf-symbols/"),
        "apns": Mark(
            systemSymbolName: "bell.badge.fill",
            brandHex: "000000",
            source: "https://developer.apple.com/design/human-interface-guidelines/sf-symbols/"),
        "developer-id": Mark(
            systemSymbolName: "person.text.rectangle.fill",
            brandHex: "000000",
            source: "https://developer.apple.com/design/human-interface-guidelines/sf-symbols/"),
    ]

    /// Regional consoles and subscription plans issue distinct credentials, but their public brand
    /// identity is shared. Keep the security contract split in ProviderCatalog while reusing the
    /// provider-owned artwork here.
    private static let providerAliases: [String: String] = [
        "kimi-global": "kimi",
        "kimi-code": "kimi",
        "zhipu-coding": "zhipu",
        "zai": "zhipu",
        "zai-coding": "zhipu",
        "zhipu-cn": "zhipu",
        "zhipu-cn-coding": "zhipu",
        "zai-global": "zhipu",
        "zai-global-coding": "zhipu",
        "siliconflow-global": "siliconflow",
        "minimax-global": "minimax",
        "minimax-token-plan-cn": "minimax",
        "minimax-token-plan-global": "minimax",
        "alibaba-bailian-coding-cn": "alibaba-bailian",
        "alibaba-bailian-token-cn": "alibaba-bailian",
        "alibaba-bailian-sg": "alibaba-bailian",
        "alibaba-bailian-us": "alibaba-bailian",
        "alibaba-bailian-hk": "alibaba-bailian",
        "volcengine-ark-coding": "volcengine-ark",
        "cloudflare-account": "cloudflare",
        "neon-org": "neon",
        "railway-api": "railway",
        "aws-sts": "aws",
        "aws-bedrock-short-term": "aws",
        "aws-bedrock-long-term": "aws",
        "pypi-test": "pypi",
        "dockerhub-oat": "dockerhub",
        "posthog-eu": "posthog",
        "sendgrid-eu": "sendgrid",
        "app-store-connect-individual": "app-store-connect",
        "apple-notary-api-key": "apple-notary",
        "developer-id-installer": "developer-id",
        "lark": "feishu",
        "slack-oauth-rotating": "slack",
    ]

    /// A provider-owned asset is not automatically licensed for a third-party product picker.
    /// These providers either require written permission or explicitly restrict this use, so their
    /// generated artwork is removed and the UI falls back to a branded-colour letter.
    private static let lettermarkOnly: Set<String> = ["mailgun"]

    static let marks: [String: Mark] = {
        var result = bundledOfficialMarks.merging(directOfficialMarks) { _, direct in direct }
        for providerId in lettermarkOnly { result.removeValue(forKey: providerId) }
        for (providerId, artworkId) in providerAliases {
            if let artwork = result[artworkId] {
                result[providerId] = artwork
            }
        }
        return result
    }()

    /// The remaining providers deliberately use a lettermark. Colours come from their published
    /// brand pages or the primary accent used by the provider's own console.
    private static let lettermarkBrandHexes: [String: String] = [
        "groq": "F55036",
        "volcengine-ark": "165DFF",
        "aws": "FF9900",
        "azure": "0078D4",
        "twilio": "F22F46",
        "sendgrid": "1A82E2",
        "app-store-connect": "0D96F6",
        "apple-notary": "000000",
        "apns": "000000",
        "developer-id": "000000",
        "posthog": "F9BD2B",
        "mailgun": "F06B66",
        "telegram": "26A5E4",
    ]

    /// Official pages used to choose the colour and, where relevant, to confirm that a third-party
    /// logo is unavailable or needs separate permission. Kept beside the fallback decision so a
    /// future official asset can replace the letter without guesswork.
    private static let lettermarkSourceURLs: [String: String] = [
        "groq": "https://groq.com/trademark-policy",
        "volcengine-ark": "https://www.volcengine.com/",
        "aws": "https://aws.amazon.com/trademark-guidelines/",
        "azure": "https://azure.microsoft.com/",
        "twilio": "https://www.twilio.com/en-us/company/brand",
        "sendgrid": "https://sendgrid.com/",
        "app-store-connect": "https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html",
        "apple-notary": "https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html",
        "apns": "https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html",
        "developer-id": "https://www.apple.com/legal/intellectual-property/guidelinesfor3rdparties.html",
        "posthog": "https://posthog.com/handbook/brand/assets",
        "mailgun": "https://www.mailgun.com/legal/terms/",
        "telegram": "https://telegram.org/tos/bot-developers",
    ]

    static let brandHexes: [String: String] = {
        var result = marks.mapValues(\.brandHex)
        result.merge(lettermarkBrandHexes) { current, _ in current }
        for (providerId, baseId) in providerAliases {
            if let color = result[baseId] { result[providerId] = color }
        }
        // New catalog contracts can ship before artwork research. Neutral letter fallback is
        // intentionally not claimed to be an official brand colour; never borrow another logo.
        return Dictionary(uniqueKeysWithValues: ProviderCatalog.all.map { ($0.id, result[$0.id] ?? "6B7280") })
    }()

    static let sourceURLs: [String: String] = {
        var result = marks.mapValues(\.source)
        result.merge(lettermarkSourceURLs) { current, _ in current }
        for (providerId, baseId) in providerAliases {
            if let source = result[baseId] { result[providerId] = source }
        }
        return Dictionary(uniqueKeysWithValues: ProviderCatalog.all.map { ($0.id, result[$0.id] ?? $0.createURL) })
    }()

    static func mark(for providerId: String?) -> Mark? { providerId.flatMap { marks[$0] } }

    /// An offline NSImage rendered from the bundled official SVG/PNG data.
    static func image(for providerId: String, size: CGFloat = 64, darkSurface: Bool = false) -> NSImage? {
        guard let mark = marks[providerId] else { return nil }
        let data: Data
        if let symbolName = mark.systemSymbolName {
            guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
                return nil
            }
            image.isTemplate = true
            return image
        } else if let pngBase64 = mark.pngBase64, let decoded = Data(base64Encoded: pngBase64) {
            data = decoded
        } else if let body = darkSurface ? (mark.darkSVGBody ?? mark.svgBody) : mark.svgBody {
            let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(mark.viewBox)" width="\(Int(size))" height="\(Int(size))">\(body)</svg>
            """
            data = Data(svg.utf8)
        } else {
            return nil
        }
        guard let image = NSImage(data: data) else { return nil }
        image.isTemplate = mark.isTemplate
        return image
    }

    static func brandColor(for providerId: String) -> Color? {
        guard let hex = brandHexes[providerId], let value = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }

    /// Preserve the brand hue against a dark surface. Very dark official marks use their white
    /// monochrome counterpart; dark chromatic colours are lifted without changing hue.
    static func visibleBrandColor(for providerId: String, onDarkSurface: Bool) -> Color? {
        guard let hex = brandHexes[providerId], let value = UInt32(hex, radix: 16) else { return nil }
        let color = NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1)
        guard onDarkSurface else { return Color(nsColor: color) }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if brightness < 0.72 {
            if saturation < 0.08 { return .white }
            return Color(nsColor: NSColor(
                calibratedHue: hue,
                saturation: min(saturation, 0.8),
                brightness: 0.82,
                alpha: alpha))
        }
        return Color(nsColor: color)
    }

    /// The initial for a provider without a usable mark ("O" for OpenAI).
    static func letter(for providerId: String) -> String {
        let name = ProviderCatalog.find(providerId)?.name ?? providerId
        return name.first.map { String($0).uppercased() } ?? "?"
    }
}

/// The mark, or the lettermark, at a size. `colored` draws the brand colour; otherwise it
/// takes the foreground colour of its surroundings.
struct ProviderMark: View {
    @Environment(\.colorScheme) private var colorScheme

    let providerId: String
    var size: CGFloat = 20
    var colored = false
    var onLightSurface = false

    var body: some View {
        if let image = ProviderMarks.image(
            for: providerId,
            size: size * 2,
            darkSurface: colorScheme == .dark && !onLightSurface
        ) {
            if image.isTemplate {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .foregroundColor(colored ? displayBrandColor : nil)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            }
        } else {
            Text(ProviderMarks.letter(for: providerId))
                .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
                .frame(width: size, height: size)
                .foregroundColor(colored ? displayBrandColor : .primary)
        }
    }

    /// Provider tiles always sit on white; inline marks follow the window appearance.
    private var displayBrandColor: Color {
        ProviderMarks.visibleBrandColor(
            for: providerId,
            onDarkSurface: colorScheme == .dark && !onLightSurface) ?? .primary
    }
}

/// The real icon of the program asking, when the Mac has it: an app caller's own bundle, or the
/// desktop app that belongs to a command-line agent (Claude Code → Claude, Codex CLI → Codex).
/// Nothing is bundled; the icon comes from the user's own installation, or a lettermark.
enum CallerAppIcon {
    /// Command-line agents and the desktop apps whose icon represents them.
    static let desktopApps: [String: [String]] = [
        "com.anthropic.claude-code": ["com.anthropic.claudefordesktop"],
        "com.openai.codex": ["com.openai.codex"],
    ]

    static func desktopBundleIds(for callerId: String) -> [String] {
        (desktopApps[callerId] ?? []) + [callerId]
    }

    static func image(for callerId: String) -> NSImage? {
        for bundleId in desktopBundleIds(for: callerId) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }
}

struct CallerMark: View {
    /// A bundle identifier when the caller has one ("com.openai.codex"), else a display name.
    let callerId: String
    var size: CGFloat = 20

    var body: some View {
        if let image = CallerAppIcon.image(for: callerId) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .cornerRadius(size * 0.2)
        } else {
            Text(callerId.split(separator: ".").last.map { String($0.prefix(1)).uppercased() } ?? "?")
                .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.22).fill(Color.secondary.opacity(0.18)))
        }
    }
}

//----------------------------------------------------------------------------------------------------------------------
// ShadowEx : Angle-based SSAO (UE4 style) for lilToon 2.x
// ref: https://takumifukasawa.hatenablog.com/entry/unity-ssao-custom-post-process
// ref: https://github.com/takumifukasawa/UnitySSAOBuiltinPipeline (SSAOAngleBased.shader)
//
// AO計算の本体は custom_insert.hlsl の lilShadowExCalcSSAO() に実装。
// _CameraDepthTexture が有効な場合のみ動作する(VRChatではシャドウ付き
// Directional Light が存在するワールドで有効になる)。無効時は素通し。
//----------------------------------------------------------------------------------------------------------------------

//----------------------------------------------------------------------------------------------------------------------
// Macro

// Custom variables
#define LIL_CUSTOM_PROPERTIES \
    float4 _CustomSSAOColor; \
    float  _CustomSSAOEnabled; \
    float  _CustomSSAOStrength; \
    float  _CustomSSAOPower; \
    float  _CustomSSAOSampleLength; \
    float  _CustomSSAOMinDistance; \
    float  _CustomSSAOMaxDistance; \
    float  _CustomSSAOBias; \
    float  _CustomSSAODither; \
    float  _CustomSSAOQuality; \
    float  _CustomExtraNormalEnabled; \
    float  _CustomExtraNormalStrengthA; \
    float  _CustomExtraNormalStrengthB; \
    float4 _CustomExtraNormal1stScale; \
    float4 _CustomExtraNormal2ndScale; \
    float4 _CustomRim2ndColor; \
    float  _CustomRim2ndEnabled; \
    float  _CustomRim2ndMode; \
    float  _CustomRim2ndPower; \
    float  _CustomRim2ndBorder; \
    float  _CustomRim2ndBlur; \
    float  _CustomRim2ndEnableLighting; \
    float  _CustomRim2ndShadowMask; \
    float  _CustomRim2ndDepthWidth; \
    float  _CustomRim2ndDepthThreshold; \
    float4 _CustomSpecColor; \
    float  _CustomSpecEnabled; \
    float  _CustomSpecSmoothness; \
    float  _CustomSpecStrength; \
    float  _CustomSpecBlendMode; \
    float  _CustomSpecEnableLighting; \
    float  _CustomSpecShadowMask; \
    float  _CustomSpecMaskChannel;

// Custom textures
// (_CameraDepthTexture は lilToon 側 (lil_common_input.hlsl) で宣言済みのため追加宣言しない)
// _CustomExtraNormalTex は専用サンプラーを宣言せず lilToon 共有サンプラー
// (sampler_linear_repeat) を再利用する。DX11 のサンプラースロット(16)を消費しないため。
// _CustomFXMask は複数の質感FXが共有するRGBAマスク (1サンプルで最大4マスク)。
// こちらも共有サンプラー (sampler_linear_repeat) を再利用する。
#define LIL_CUSTOM_TEXTURES \
    TEXTURE2D(_CustomExtraNormalTex); \
    TEXTURE2D(_CustomFXMask);

// Add vertex shader output
// SSAOの中心点計算にワールド座標を使うため強制的に v2f へ含める
#define LIL_V2F_FORCE_POSITION_WS

// 追加ノーマルマップ (1枚のRGBAに2枚分パック) を lilToon のノーマル処理内で合成する。
// lilToon は BEFORE_NORMAL_2ND の直後に normalmap を fd.N へ変換 (world) し、
// fd.ln / fd.uvMat / fd.reflectionN / fd.matcapN 等の派生値もまとめて再計算する。
// そのため接線空間の normalmap にディテールを積むことで、追加処理を書かずとも
// ライティング・MatCap・リム・反射すべてに反映される。
// 1st(RG)と2nd(BA)は別UV(タイリング)でサンプルするため同一テクスチャを2回サンプルする
// (テクスチャ「枚数」は1枚のまま。サンプラーも共有サンプラーを再利用)。
// ※ この注入は lilToon のノーマルマップ機能が有効なとき (LIL_FEATURE_NORMAL) に動作する。
#define BEFORE_NORMAL_2ND \
    if (_CustomExtraNormalEnabled > 0.5) \
    { \
        float2 exUV1 = fd.uv0 * _CustomExtraNormal1stScale.xy; \
        float2 exUV2 = fd.uv0 * _CustomExtraNormal2ndScale.xy; \
        float2 exChA = LIL_SAMPLE_2D(_CustomExtraNormalTex, sampler_linear_repeat, exUV1).rg; \
        float2 exChB = LIL_SAMPLE_2D(_CustomExtraNormalTex, sampler_linear_repeat, exUV2).ba; \
        float3 exNA = lilShadowExDecodeNormalCh(exChA, _CustomExtraNormalStrengthA); \
        float3 exNB = lilShadowExDecodeNormalCh(exChB, _CustomExtraNormalStrengthB); \
        normalmap = lilShadowExBlendNormalUDN(normalmap, exNA); \
        normalmap = lilShadowExBlendNormalUDN(normalmap, exNB); \
    }

// リムライト2nd (フレネル型 / 深度輪郭型) を合成する。
// 注入点は BEFORE_BLEND_EMISSION。ここは full/lite 両パスに存在し、かつ
// #ifndef LIL_PASS_FORWARDADD の内側 (ベースパス限定) なので、リアルタイム追加
// ライトのパスで定数リムが二重加算されるのを防げる (lilToon本体もadd時は定数リムを無効化)。
//   Mode 0 = フレネル型 : abs(dot(N,V)) から輪郭を出す。追加サンプル無し。
//   Mode 1 = 深度輪郭型 : _CameraDepthTexture を再利用しシルエット境界を検出。
//            LIL_ENABLED_DEPTH_TEX が有効なワールドでのみ動作 (無効時は素通し)。
// _CustomRim2ndEnableLighting でライト色乗算 (0=定数色 / 1=ライト追従) を補間。
//
// 追加スペキュラ (質感系) も同じ注入点に相乗り。ベースパス限定なので追加ライトで
// 二重加算されず、full/lite 両パスに存在するため Lite でも効く。
//   スタイライズド Blinn-Phong を fd.N/fd.V/fd.L から算出し、共有FXマスク
//   (_CustomFXMask) の任意chで強度をマスク、lilBlendColor でブレンド。
#define BEFORE_BLEND_EMISSION \
    if (_CustomRim2ndEnabled > 0.5) \
    { \
        float rim2 = 0.0; \
        if (_CustomRim2ndMode < 0.5) \
        { \
            float nvabs = abs(dot(fd.N, fd.V)); \
            rim2 = pow(saturate(1.0 - nvabs), max(_CustomRim2ndPower, 0.01)); \
            rim2 = lilTooningScale(_AAStrength, rim2, _CustomRim2ndBorder, _CustomRim2ndBlur); \
        } \
        else if (LIL_ENABLED_DEPTH_TEX) \
        { \
            float centerEyeDepth = -mul(LIL_MATRIX_V, float4(fd.positionWS, 1.0)).z; \
            rim2 = lilShadowExDepthContour(fd.positionCS.xy, centerEyeDepth, _CustomRim2ndDepthWidth, _CustomRim2ndDepthThreshold); \
        } \
        rim2 = lerp(rim2, rim2 * fd.shadowmix, _CustomRim2ndShadowMask); \
        float3 rim2Col = lerp(_CustomRim2ndColor.rgb, _CustomRim2ndColor.rgb * fd.lightColor, _CustomRim2ndEnableLighting); \
        fd.col.rgb += rim2Col * (rim2 * _CustomRim2ndColor.a); \
    } \
    if (_CustomSpecEnabled > 0.5) \
    { \
        float spec = lilShadowExSpecular(fd.N, fd.V, fd.L, fd.ln, _CustomSpecSmoothness); \
        float specMask = lilShadowExSelectCh(LIL_SAMPLE_2D(_CustomFXMask, sampler_linear_repeat, fd.uvMain), _CustomSpecMaskChannel); \
        float specAmt = spec * _CustomSpecStrength * specMask * _CustomSpecColor.a; \
        specAmt = lerp(specAmt, specAmt * fd.shadowmix, _CustomSpecShadowMask); \
        float3 specCol = lerp(_CustomSpecColor.rgb, _CustomSpecColor.rgb * fd.lightColor, _CustomSpecEnableLighting); \
        fd.col.rgb = lilBlendColor(fd.col.rgb, specCol, saturate(specAmt), (uint)_CustomSpecBlendMode); \
    }

// Inserting a process into pixel shader
// エミッション加算の直前に適用することで、発光部分を暗くせずにAOをかける。
// LIL_ENABLED_DEPTH_TEX: 深度テクスチャが無いワールドでは自動的に無効化される。
#define BEFORE_EMISSION_1ST \
    if (_CustomSSAOEnabled > 0.5 && LIL_ENABLED_DEPTH_TEX) \
    { \
        float aoRate = lilShadowExCalcSSAO(fd.positionWS, fd.positionCS); \
        float aoFactor = saturate(pow(saturate(aoRate), _CustomSSAOPower) * _CustomSSAOStrength); \
        fd.col.rgb = lerp(fd.col.rgb, _CustomSSAOColor.rgb, aoFactor * _CustomSSAOColor.a); \
    }

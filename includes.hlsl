// VRChatがランタイムで設定するグローバル変数。シェーダー本体(NonToon/Shader-Core)は宣言していないため、
// 使う側のモジュールで宣言する必要がある。他モジュールと二重宣言にならないようガードする
#ifndef SC_VRCHAT_MIRROR_MODE_DECLARED
#define SC_VRCHAT_MIRROR_MODE_DECLARED
float _VRChatMirrorMode;
#endif

//----------------------------------------------------------------------------------------------------------------------
// Angle-based SSAO (UE4 style) ヘルパー
// ref: custom_insert.hlsl (ShadowEx)
//----------------------------------------------------------------------------------------------------------------------

// サンプリングパターン: 回転角は 0..2π を6分割した各区間内、
// 距離は 0.1..1.0 を6分割した各区間内から選んだ値を定数として焼き込み
static const float SC_SSAO_ROTATIONS[6] = {0.401, 1.532, 2.401, 3.665, 4.510, 5.788};
static const float SC_SSAO_DISTANCES[6] = {0.187, 0.331, 0.399, 0.542, 0.712, 0.874};

// スクリーンUVの深度 (linear eye depth) を取得する。画面外の場合は false を返す。
// Shader-Core では SCGetFrameDepth(uv) が linear eye depth を返すのでそれを利用する。
// UVは呼び出し側で射影済み (射影はサンプル間で共有できるためループ外へ巻き上げている)
bool com_dennokoworks_ssao_SampleEyeDepth(float2 uv, out float eyeDepth)
{
    eyeDepth = 0.0;

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return false;

    eyeDepth = SCGetFrameDepth(uv);
    return (eyeDepth > 0.001);
}

// offsetVS のピクセルを通る視線レイ上で、深度 eyeDepth にある点を復元する
float3 com_dennokoworks_ssao_ReconstructVS(float3 offsetVS, float eyeDepth)
{
    return offsetVS * (eyeDepth / max(-offsetVS.z, 0.0001));
}

// Interleaved Gradient Noise (ディザ回転用)
// ref: Jimenez 2014, "Next Generation Post Processing in Call of Duty: Advanced Warfare"
float com_dennokoworks_ssao_IGN(float2 positionCS)
{
    return frac(52.9829189 * frac(dot(positionCS, float2(0.06711056, 0.00583715))));
}

// 1サンプル点分の遮蔽寄与を計算する。
// 戻り値は falloff 重み付きの符号付き角度 (d * falloff)。棄却されたサンプルは 0。
// 符号付きのまま返すことで、呼び出し側が「各サンプル独立の max(0,c)」と
// 「対称ペア和 max(0, cA+cB) による同一平面成分の相殺」を選べる
float com_dennokoworks_ssao_SampleOcclusion(float2 uv, float3 samplePosVS, float3 centerVS,
    float centerEyeDepth, float3 surfaceToCameraDir, float biasValue,
    float minDistSq, float maxDistSq, float rcpMaxDist)
{
    float eyeDepth;
    if (!com_dennokoworks_ssao_SampleEyeDepth(uv, eyeDepth)) return 0.0;

    // ほぼ同一深度 (同一平面) のサンプルはAOに寄与させない
    if (abs(centerEyeDepth - eyeDepth) < biasValue) return 0.0;

    float3 diff = com_dennokoworks_ssao_ReconstructVS(samplePosVS, eyeDepth) - centerVS;
    // sqrt を棄却判定の後まで遅延させるため二乗距離で比較する
    float distSq = dot(diff, diff);
    if (distSq < minDistSq || distSq > maxDistSq) return 0.0;

    float dist = sqrt(distSq);
    // 中心→サンプル点の方向がカメラ方向へ傾くほど遮蔽されていると判定
    float d = dot(diff / dist, surfaceToCameraDir);
    // 遠いサンプルほど寄与を減衰させてソフトな見た目にする
    float falloff = 1.0 - saturate(dist * rcpMaxDist);
    return d * falloff;
}


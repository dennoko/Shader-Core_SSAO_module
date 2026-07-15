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

// ビュー空間位置が投影されるピクセルの深度 (linear eye depth) を取得する。
// 画面外・カメラ背後の場合は false を返す。
// Shader-Core では SCGetFrameDepth(uv) が linear eye depth を返すのでそれを利用する。
bool com_dennokoworks_ssao_SampleEyeDepth(float3 positionVS, out float eyeDepth)
{
    eyeDepth = 0.0;

    float4 positionCS = mul(SC_V2P(), float4(positionVS, 1.0));
    if (positionCS.w < 0.0001) return false;

    // 透視除算して NDC → UV 変換
    float2 ndc = positionCS.xy / positionCS.w;
    float2 uv = ndc * 0.5 + 0.5;
    // Direct3D系ではY軸が反転する場合があるが、SCGetFrameDepthのUVは
    // vertex.uvDepth と同じ座標系を期待する。SC_V2P() による投影結果から
    // 求めたUVは _ProjectionParams.x で反転補正が必要な場合がある
    #if UNITY_UV_STARTS_AT_TOP
        uv.y = 1.0 - uv.y;
    #endif

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


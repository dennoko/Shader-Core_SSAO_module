//----------------------------------------------------------------------------------------------------------------------
// ShadowEx : Angle-based SSAO (UE4 style)
// ref: https://takumifukasawa.hatenablog.com/entry/unity-ssao-custom-post-process
// ref: https://github.com/takumifukasawa/UnitySSAOBuiltinPipeline (SSAOAngleBased.shader)
//
// アルゴリズム概要:
//   1. フラグメントのビュー空間位置を中心点とする
//   2. 6方向 × 対称2点 (A/B) = 12回の深度サンプリングを1セットとする
//   3. 各サンプル点のビュー空間位置を深度から復元
//   4. 「中心→サンプル点」の方向と「中心→カメラ」の方向の内積 (角度) を平均して遮蔽度とする
//      (遮蔽物が手前にあるほどサンプル方向がカメラ側へ傾き、内積が大きくなる)
//
// 平滑化 (ポストプロセスのブラーパスの代替):
//   - Quality: サンプリングパターンを 60°/K ずつ回転させながらK回実行して平均。
//     角度方向の隙間が埋まりバンディングが消える (インライン回転スーパーサンプリング)
//   - Dither: Interleaved Gradient Noise でピクセルごとにパターンを回転。
//     ノイズが高周波かつ均一に分散するため、目の空間積分で滑らかに見える
//----------------------------------------------------------------------------------------------------------------------

// サンプリングパターン: 参照実装 (SSAOAngleBased.cs) と同様に
// 回転角は 0..2π を6分割した各区間内、距離は 0.1..1.0 を6分割した各区間内から
// 選んだ値を定数として焼き込み (元実装はCPU側で乱数生成して配列で渡している)
static const float LIL_SHADOWEX_SSAO_ROTATIONS[6] = {0.401, 1.532, 2.401, 3.665, 4.510, 5.788};
static const float LIL_SHADOWEX_SSAO_DISTANCES[6] = {0.187, 0.331, 0.399, 0.542, 0.712, 0.874};

// ビュー空間位置が投影されるピクセルの深度 (linear eye depth) を取得する。
// 画面外・カメラ背後・深度未書き込み (far plane) の場合は false を返す。
bool lilShadowExSampleEyeDepth(float3 positionVS, out float eyeDepth)
{
    eyeDepth = 0.0;

    float4 positionCS = mul(LIL_MATRIX_P, float4(positionVS, 1.0));
    if (positionCS.w < 0.0001) return false;

    // lilToonの提供する変換関数を利用して、プラットフォームごとの差異やレンダーテクスチャ反転を解決する
    float4 positionSS = lilTransformCStoSS(positionCS);
    float2 uv = positionSS.xy / positionSS.w;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return false;

    float2 texel = uv * LIL_SCREENPARAMS.xy;
    float rawDepth = LIL_GET_DEPTH_TEX_CS(texel).r;
    #if defined(UNITY_REVERSED_Z)
        if (rawDepth <= 0.0) return false; // 深度未書き込み
    #else
        if (rawDepth >= 1.0) return false;
    #endif

    // ミラー (oblique projection) も考慮した linear eye depth 変換
    eyeDepth = LIL_TO_LINEARDEPTH(rawDepth, texel);
    return true;
}

// offsetVS のピクセルを通る視線レイ上で、深度 eyeDepth にある点を復元する
float3 lilShadowExReconstructVS(float3 offsetVS, float eyeDepth)
{
    return offsetVS * (eyeDepth / max(-offsetVS.z, 0.0001));
}

// Interleaved Gradient Noise (ディザ回転用)
// ピクセル間で位相が規則的に分散するため、sinハッシュよりノイズが均一で滑らかに見える
// ref: Jimenez 2014, "Next Generation Post Processing in Call of Duty: Advanced Warfare"
float lilShadowExIGN(float2 positionCS)
{
    return frac(52.9829189 * frac(dot(positionCS, float2(0.06711056, 0.00583715))));
}

// 1サンプル点分の遮蔽寄与を計算する (寄与なしで0)
float lilShadowExSampleOcclusion(float3 offsetPos, float3 centerVS, float centerEyeDepth, float3 surfaceToCameraDir, float minDist)
{
    float eyeDepth;
    if (!lilShadowExSampleEyeDepth(offsetPos, eyeDepth)) return 0.0;

    // ほぼ同一深度 (同一平面) のサンプルはAOに寄与させない
    if (abs(centerEyeDepth - eyeDepth) < _CustomSSAOBias) return 0.0;

    float3 samplePos = lilShadowExReconstructVS(offsetPos, eyeDepth);
    float dist = distance(samplePos, centerVS);
    if (dist < minDist || dist > _CustomSSAOMaxDistance) return 0.0;

    // 中心→サンプル点の方向がカメラ方向へ傾くほど遮蔽されていると判定
    float d = dot((samplePos - centerVS) / dist, surfaceToCameraDir);
    // 遠いサンプルほど寄与を減衰させてソフトな見た目にする
    float falloff = 1.0 - saturate(dist / _CustomSSAOMaxDistance);
    return max(0.0, d) * falloff;
}

//----------------------------------------------------------------------------------------------------------------------
// ShadowEx : 追加ノーマルマップ (1枚のRGBAに2枚分をパック)
//
//   RG = 1枚目の接線空間法線XY, BA = 2枚目の接線空間法線XY。Zはシェーダーで復元する。
//   1サンプルで2枚分の法線を扱えるためテクスチャ枚数を削減できる。
//
//   ※ パックテクスチャは Unity の「Normal map」ではなく「Default (sRGBオフ/Linear)」で
//      インポートすること。Normal map インポートは DXT5nm の AG スウィズルを行うため、
//      RG/BA パッキングが壊れる。
//----------------------------------------------------------------------------------------------------------------------

// 0..1 の2ch から接線空間法線を復元する。strength で XY を増幅する (UDN的に Z が潰れる)。
float3 lilShadowExDecodeNormalCh(float2 ch, float strength)
{
    float2 xy = (ch * 2.0 - 1.0) * strength;
    float z = sqrt(saturate(1.0 - dot(xy, xy)));
    return float3(xy, z);
}

// UDNブレンド: ベース法線 (lilToonの1st等) の Z を保ちつつ、ディテール法線の XY を積む。
// 加算のみで正規化1回と軽量。強い凹凸でも破綻しにくい。
float3 lilShadowExBlendNormalUDN(float3 baseN, float3 detailN)
{
    return normalize(float3(baseN.xy + detailN.xy, baseN.z));
}

//----------------------------------------------------------------------------------------------------------------------
// ShadowEx : 深度輪郭リムライト用ヘルパー
//
//   現在ピクセルのサーフェス深度と、上下左右 widthPixels ピクセル先のシーン深度を比較し、
//   近傍が奥にある (= シルエット境界) ほど大きい輪郭係数 (0..1) を返す。
//   _CameraDepthTexture を再利用するため追加サンプラーは消費しない。
//----------------------------------------------------------------------------------------------------------------------
float lilShadowExDepthContour(float2 pixelCoord, float centerEyeDepth, float widthPixels, float threshold)
{
    float edge = 0.0;
    float2 offs[4] = { float2(widthPixels, 0.0), float2(-widthPixels, 0.0), float2(0.0, widthPixels), float2(0.0, -widthPixels) };
    [unroll]
    for (uint i = 0; i < 4; i++)
    {
        float2 texel = pixelCoord + offs[i];
        float rawDepth = LIL_GET_DEPTH_TEX_CS(texel).r;
        float neighborDepth = LIL_TO_LINEARDEPTH(rawDepth, texel);
        // 近傍が奥 = シルエット境界。差が threshold を超えた分を滑らかに係数化。
        edge = max(edge, smoothstep(threshold, threshold * 2.0, neighborDepth - centerEyeDepth));
    }
    return edge;
}

//----------------------------------------------------------------------------------------------------------------------
// ShadowEx : 共有FXマスク & 追加スペキュラ用ヘルパー
//
//   複数の質感FXが1枚のRGBAマスクを共有し、各FXが _CustomXxxMaskChannel で
//   使用チャンネル(0=R/1=G/2=B/3=A)を選ぶ。テクスチャ枚数とサンプル数を削減する。
//----------------------------------------------------------------------------------------------------------------------

// RGBA から1チャンネルを選択して返す (0=R/1=G/2=B/3=A)
float lilShadowExSelectCh(float4 packed, float channel)
{
    if (channel < 0.5) return packed.r;
    if (channel < 1.5) return packed.g;
    if (channel < 2.5) return packed.b;
    return packed.a;
}

// スタイライズド Blinn-Phong スペキュラ量 (0..) を返す。
//   smoothness(0..1) をハイライトの鋭さ (指数) に変換し、N・L>0 の受光面のみに出す。
float lilShadowExSpecular(float3 N, float3 V, float3 L, float ndl, float smoothness)
{
    float3 halfDir = normalize(L + V);
    float nh = saturate(dot(N, halfDir));
    float specPow = exp2(saturate(smoothness) * 10.0 + 1.0); // 2..2048
    return pow(nh, specPow) * saturate(ndl);
}

// アングルベースAO本体。遮蔽度 (0..1) を返す。
float lilShadowExCalcSSAO(float3 positionWS, float4 positionCS)
{
    // 平行投影では視線レイによる復元が成り立たないためスキップ
    if (!lilIsPerspective()) return 0.0;

    float3 centerVS = mul(LIL_MATRIX_V, float4(positionWS, 1.0)).xyz;
    float centerEyeDepth = -centerVS.z;
    float3 surfaceToCameraDir = -normalize(centerVS);

    // ピクセルごとにサンプリングパターンを回転してバンディングをノイズ化 (任意)
    float ditherRad = _CustomSSAODither > 0.5 ? lilShadowExIGN(positionCS.xy) * (2.0 * LIL_PI) : 0.0;

    float minDist = max(_CustomSSAOMinDistance, 0.0001);
    uint iterations = (uint)clamp(_CustomSSAOQuality + 0.5, 1.0, 4.0);
    // パターンは約60°周期なので、反復ごとに 60°/K ずつ回転させて角度の隙間を埋める
    float iterationStep = (LIL_PI / 3.0) / (float)iterations;

    float occludedAcc = 0.0;

    for (uint k = 0; k < iterations; k++)
    {
        float baseRad = ditherRad + iterationStep * (float)k;

        for (uint i = 0; i < 6; i++)
        {
            float rad = LIL_SHADOWEX_SSAO_ROTATIONS[i] + baseRad;
            // 反復ごとに距離の割り当てもローテーションし、半径方向の隙間も埋める
            float offsetLen = LIL_SHADOWEX_SSAO_DISTANCES[(i + k) % 6] * _CustomSSAOSampleLength;
            float2 dir;
            sincos(rad, dir.y, dir.x);

            // ビュー空間XY平面上の対称2点
            float3 offsetA = float3(dir * offsetLen, 0.0);
            occludedAcc += lilShadowExSampleOcclusion(centerVS + offsetA, centerVS, centerEyeDepth, surfaceToCameraDir, minDist);
            occludedAcc += lilShadowExSampleOcclusion(centerVS - offsetA, centerVS, centerEyeDepth, surfaceToCameraDir, minDist);
        }
    }

    // (6方向 × 対称2点 × 反復数) の平均を返す
    return occludedAcc / (12.0 * (float)iterations);
}

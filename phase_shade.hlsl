{
    // ミラーではミラーカメラ用の深度テクスチャが生成されず、グローバルにはメインカメラの
    // 深度が残ったままになる。解像度が一致すると SCIsFrameDepthGenerated() を通過してしまい、
    // 別視点の深度を参照して破綻するため既定で切る
    bool isMirror = (_VRChatMirrorMode != 0);
    bool depthUsable = SCIsFrameDepthGenerated() && SCIsPerspective() && !(_DisableInMirror && isMirror);

    if (_Enable && depthUsable)
    {
        // アングルベースSSAO (UE4 style)
        // ref: custom_insert.hlsl (ShadowEx)
        //
        // アルゴリズム概要:
        //   1. フラグメントのビュー空間位置を中心点とする
        //   2. 6方向 × 対称2点 (A/B) = 12回の深度サンプリングを1セットとする
        //   3. 各サンプル点のビュー空間位置を深度から復元
        //   4. 「中心→サンプル点」の方向と「中心→カメラ」の方向の内積 (角度) を平均して遮蔽度とする
        //      (遮蔽物が手前にあるほどサンプル方向がカメラ側へ傾き、内積が大きくなる)
        //
        // 距離系パラメータは FoV と距離から求めた「見かけサイズ」で正規化しており、
        // 視条件に依らず画面上の見え方が一定になる (viewScale 参照)

        float3 centerVS = mul(SC_W2V(), float4(vertex.position, 1.0)).xyz;
        float centerEyeDepth = -centerVS.z;

        float4x4 v2p = SC_V2P();

        // FoV・距離補正: 基準 (FoV60°, 1m) の見かけサイズに正規化し、FoV設定やカメラズーム、
        // VR/デスクトップの違いに依らず画面上のAOの見え方を均一化する。
        // _m11 = 1/tan(fovY/2)。VRでは片目ごとの射影が入るためHMDのFoVも自動反映される
        const float REF_M11 = 1.7320508; // 1/tan(30°) = FoV 60°
        float apparentDist = centerEyeDepth * REF_M11 / abs(v2p._m11);
        float viewScale = max(apparentDist, 0.01);

        // 遠景ではサンプル間隔に対して深度差が粗くなるためフェードアウトさせる。
        // 距離は見かけ距離で判定するため、ズーム撮影 (大写し) ではフェードしない。
        // フェードとマスクはループ前に確定するので、結果が0ならサンプリングごとスキップする
        float fadeLength = max(_FadeDistance * 0.25, 1e-3);
        float fade = saturate((_FadeDistance - apparentDist) / fadeLength);
        half maskVal = sd.mask[_MaskChannel];

        if (fade * maskVal > 0.001)
        {
            float3 surfaceToCameraDir = -normalize(centerVS);

            // ピクセルごとにサンプリングパターンを回転してバンディングをノイズ化 (任意)
            float ditherRad = _Dither > 0.5 ? com_dennokoworks_ssao_IGN(vertex.positionRaw.xy) * 6.2831853 : 0.0;

            // 距離系パラメータは「FoV60°・距離1mで見たときの値」として viewScale でスケールする
            float sampleLen = _SampleLength * viewScale;
            float minDist = max(_MinDistance * viewScale, 0.0001);
            float maxDist = max(_MaxDistance * viewScale, 0.001);
            float minDistSq = minDist * minDist;
            float maxDistSq = maxDist * maxDist;
            float rcpMaxDist = 1.0 / maxDist;
            float biasValue = _Bias * viewScale;
            uint iterations = (uint)clamp(_Quality + 0.5, 1.0, 4.0);
            // パターンは約60°周期なので、反復ごとに 60°/K ずつ回転させて角度の隙間を埋める
            float iterationStep = (3.14159265 / 3.0) / (float)iterations;

            // サンプルオフセットは z=0 平面内なのでクリップ空間の w (= centerEyeDepth) は
            // 中心と共通。射影は中心で1回だけ行い、サンプルごとのUVは2Dのスケール加算に縮約する。
            // VRの非対称視錐台 (_m02/_m12) は z に掛かる項なので offset.z=0 により影響しない。
            // Y反転は ComputeScreenPos と同じく _ProjectionParams.x の符号に従う
            float4 centerCS = mul(v2p, float4(centerVS, 1.0));
            float rcpW = 0.5 / centerCS.w;  // 描画中のフラグメントなので w > 0 が保証される
            float2 uvScale = float2(v2p._m00, v2p._m11 * _ProjectionParams.x) * rcpW;
            float2 centerUV = float2(centerCS.x, centerCS.y * _ProjectionParams.x) * rcpW + 0.5;

            float occludedAcc = 0.0;

            for (uint k = 0; k < iterations; k++)
            {
                float baseRad = ditherRad + iterationStep * (float)k;

                for (uint i = 0; i < 6; i++)
                {
                    float rad = SC_SSAO_ROTATIONS[i] + baseRad;
                    // 反復ごとに距離の割り当てもローテーションし、半径方向の隙間も埋める
                    float offsetLen = SC_SSAO_DISTANCES[(i + k) % 6] * sampleLen;
                    float2 dir;
                    sincos(rad, dir.y, dir.x);

                    // ビュー空間XY平面上の対称2点。UVデルタは符号反転で共有できる
                    float3 offsetA = float3(dir * offsetLen, 0.0);
                    float2 uvDelta = uvScale * offsetA.xy;

                    float cA = com_dennokoworks_ssao_SampleOcclusion(centerUV + uvDelta, centerVS + offsetA,
                        centerVS, centerEyeDepth, surfaceToCameraDir, biasValue, minDistSq, maxDistSq, rcpMaxDist);
                    float cB = com_dennokoworks_ssao_SampleOcclusion(centerUV - uvDelta, centerVS - offsetA,
                        centerVS, centerEyeDepth, surfaceToCameraDir, biasValue, minDistSq, maxDistSq, rcpMaxDist);

                    // 対称ペアの合成: 通常は各サンプル独立。Reduce Self Occlusion 有効時はペア和で
                    // 同一平面成分 (cA ≈ -cB) を相殺し、グレージング角での偽遮蔽を抑える
                    occludedAcc += _ReduceSelfOcclusion ? max(0.0, cA + cB) : max(0.0, cA) + max(0.0, cB);
                }
            }

            // (6方向 × 対称2点 × 反復数) の平均
            float aoRate = occludedAcc / (12.0 * (float)iterations);

            float ao = saturate(pow(saturate(aoRate), _Power) * _Strength);

            half strength = ao * fade * maskVal;
            half3 aoColor = lerp(half3(1,1,1), _AOColor.rgb, strength);
            sd.lightColor *= aoColor;
        }
    }
}

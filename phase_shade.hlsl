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

        float3 centerVS = mul(SC_W2V(), float4(vertex.position, 1.0)).xyz;
        float centerEyeDepth = -centerVS.z;
        float3 surfaceToCameraDir = -normalize(centerVS);

        // ピクセルごとにサンプリングパターンを回転してバンディングをノイズ化 (任意)
        float ditherRad = _Dither > 0.5 ? com_dennokoworks_ssao_IGN(vertex.positionRaw.xy) * 6.2831853 : 0.0;

        float minDist = max(_MinDistance, 0.0001);
        float maxDist = max(_MaxDistance, 0.001);
        float biasValue = _Bias;
        uint iterations = (uint)clamp(_Quality + 0.5, 1.0, 4.0);
        // パターンは約60°周期なので、反復ごとに 60°/K ずつ回転させて角度の隙間を埋める
        float iterationStep = (3.14159265 / 3.0) / (float)iterations;

        float occludedAcc = 0.0;

        for (uint k = 0; k < iterations; k++)
        {
            float baseRad = ditherRad + iterationStep * (float)k;

            for (uint i = 0; i < 6; i++)
            {
                float rad = SC_SSAO_ROTATIONS[i] + baseRad;
                // 反復ごとに距離の割り当てもローテーションし、半径方向の隙間も埋める
                float offsetLen = SC_SSAO_DISTANCES[(i + k) % 6] * _SampleLength;
                float2 dir;
                sincos(rad, dir.y, dir.x);

                // ビュー空間XY平面上の対称2点
                float3 offsetA = float3(dir * offsetLen, 0.0);

                // --- サンプルA ---
                float3 samplePosA = centerVS + offsetA;
                float eyeDepthA;
                if (com_dennokoworks_ssao_SampleEyeDepth(samplePosA, eyeDepthA))
                {
                    if (abs(centerEyeDepth - eyeDepthA) >= biasValue)
                    {
                        float3 reconstructedA = com_dennokoworks_ssao_ReconstructVS(samplePosA, eyeDepthA);
                        float distA = distance(reconstructedA, centerVS);
                        if (distA >= minDist && distA <= maxDist)
                        {
                            float dA = dot((reconstructedA - centerVS) / distA, surfaceToCameraDir);
                            float falloffA = 1.0 - saturate(distA / maxDist);
                            occludedAcc += max(0.0, dA) * falloffA;
                        }
                    }
                }

                // --- サンプルB (対称点) ---
                float3 samplePosB = centerVS - offsetA;
                float eyeDepthB;
                if (com_dennokoworks_ssao_SampleEyeDepth(samplePosB, eyeDepthB))
                {
                    if (abs(centerEyeDepth - eyeDepthB) >= biasValue)
                    {
                        float3 reconstructedB = com_dennokoworks_ssao_ReconstructVS(samplePosB, eyeDepthB);
                        float distB = distance(reconstructedB, centerVS);
                        if (distB >= minDist && distB <= maxDist)
                        {
                            float dB = dot((reconstructedB - centerVS) / distB, surfaceToCameraDir);
                            float falloffB = 1.0 - saturate(distB / maxDist);
                            occludedAcc += max(0.0, dB) * falloffB;
                        }
                    }
                }
            }
        }

        // (6方向 × 対称2点 × 反復数) の平均
        float aoRate = occludedAcc / (12.0 * (float)iterations);

        float ao = saturate(pow(saturate(aoRate), _Power) * _Strength);

        // 遠景ではサンプル間隔に対して深度差が粗くなるためフェードアウトさせる
        float fadeLength = max(_FadeDistance * 0.25, 1e-3);
        float fade = saturate((_FadeDistance - centerEyeDepth) / fadeLength);

        half strength = ao * fade * sd.mask[_MaskChannel];
        half3 aoColor = lerp(half3(1,1,1), _AOColor.rgb, strength);
        sd.lightColor *= aoColor;
    }
}

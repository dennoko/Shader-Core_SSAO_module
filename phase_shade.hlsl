{
    // ミラーではミラーカメラ用の深度テクスチャが生成されず、グローバルにはメインカメラの
    // 深度が残ったままになる。解像度が一致すると SCIsFrameDepthGenerated() を通過してしまい、
    // 別視点の深度を参照して破綻するため既定で切る
    bool isMirror = (_VRChatMirrorMode != 0);
    bool depthUsable = SCIsFrameDepthGenerated() && SCIsPerspective() && !(_DisableInMirror && isMirror);

    if (_Enable && depthUsable)
    {
        // このピクセルのビュー空間深度。深度テクスチャの値(SCGetFrameDepth)と同じスケール
        float depth = vertex.positionRaw.w;

        // ビュー空間: x=右 / y=上 / z=カメラ方向(正=手前)
        float3 positionVS = mul(SC_W2V(), float4(vertex.position, 1)).xyz;
        half3 normalVS = normalize(mul((float3x3)SC_W2V(), sd.N));

        // ビュー空間のオフセット(m) → 深度テクスチャのUVオフセットへの変換係数
        float2 projScale = abs(SC_V2P()._m00_m11) * 0.5;

        // 法線を軸にした半球サンプリング用の基底
        half3 axis = abs(normalVS.z) < 0.9 ? half3(0,0,1) : half3(1,0,0);
        half3 tangentVS = normalize(cross(axis, normalVS));
        half3 binormalVS = cross(normalVS, tangentVS);

        float2 pixel = vertex.positionRaw.xy;
        float2 parity = fmod(floor(pixel), 2.0);

        // デノイズ時は2x2クアッドの4ピクセルで同じ回転を共有し、各ピクセルには同一列の別スライスを
        // 割り当てる。こうするとクアッド平均の結果が「4*sampleCount個の低ディスクレパンシ列による
        // 推定量」に一致し、タップ数を増やさずに分散が下がる。
        // デノイズ無効時はクアッド単位のノイズだと2x2のブロックが見えるのでピクセル単位に戻す
        float2 noisePixel = _Denoise ? floor(pixel * 0.5) : pixel;
        float noise = frac(52.9829189 * frac(dot(noisePixel, float2(0.06711056, 0.00583715))));
        uint sliceIndex = _Denoise ? (uint)(parity.x + 2 * parity.y) : 0u;
        uint sliceCount = _Denoise ? 4u : 1u;

        float sampleRadius = max(_Radius, 1e-3);

        // 近距離では半径が画面上で巨大になり、少ないタップでは完全な undersampling になる。
        // 投影後の半径に上限を設けて、超える場合はワールド半径のほうを縮める
        float radiusPixels = sampleRadius * projScale.x * _ScreenParams.x / depth;
        float radiusLimit = max(_MaxRadiusPixels, 1);
        sampleRadius *= min(1, radiusLimit / max(radiusPixels, 1e-4));

        float depthBias = _Bias;

        // バイアス境界での 0↔1 の飛びがサンプルごとの分散＝ノイズになるため、半径に比例した幅で滑らかに渡す
        float falloffWidth = max(sampleRadius * 0.25, 1e-4);

        // 品質: Low=4 / Medium=8 / High=16 / VeryHigh=32 サンプル
        uint sampleCount = 4u << _Quality;
        float sampleCountInv = 1.0 / sampleCount;

        float occlusion = 0;
        for (uint index = 0; index < sampleCount; index++)
        {
            // 方位角・仰角・距離を3次元の低ディスクレパンシ列(R3)から独立に取る。
            // 同じ乱数を方向と距離に使い回すと半球が法線方向に潰れた形になる
            float3 r3 = float3(0.8191725134, 0.6710436067, 0.5497004779);
            float3 xi = frac(r3 * (index * sliceCount + sliceIndex) + noise);

            // コサイン重み付き半球方向
            float angle = xi.x * 6.2831853;
            float diskRadius = sqrt(xi.y);
            float3 dirTS = float3(cos(angle) * diskRadius, sin(angle) * diskRadius, sqrt(saturate(1 - xi.y)));
            float3 dirVS = tangentVS * dirTS.x + binormalVS * dirTS.y + normalVS * dirTS.z;

            // 距離は方向と独立に決める。近距離を密にして接触部のAOを拾う
            float dist = sampleRadius * lerp(0.25, 1.0, sqrt(xi.z));
            float3 offsetVS = dirVS * dist;

            // サンプル点を透視投影してUVを求める。第2項は画面中心から外れた位置での視差
            // (サンプル点の深度が変わることで生じる横ずれ)の補正
            float sampleDepth = max(depth - offsetVS.z, 0.01);
            float2 parallax = positionVS.xy * (offsetVS.z / depth);
            float2 sampUV = vertex.uvDepth + (offsetVS.xy + parallax) * projScale / sampleDepth;

            // 深度テクスチャ上の実際の面がサンプル点より手前なら遮蔽
            float sceneDepth = SCGetFrameDepth(sampUV);
            float diff = sampleDepth - sceneDepth;
            float occ = saturate((diff - depthBias) / falloffWidth);

            // 注目ピクセルから半径以上離れた面は別の物体とみなして寄与を落とす
            float range = saturate(sampleRadius / max(abs(depth - sceneDepth), 1e-4));
            range = range * range * (3 - 2 * range);

            occlusion += occ * range;
        }

        float ao = 1 - occlusion * sampleCountInv;

        // 2x2クアッド内で平均し、少ないサンプル数でのノイズを均す
        float aoQuad = ao + ddx(ao) * (0.5 - parity.x) + ddy(ao) * (0.5 - parity.y);
        ao = _Denoise ? aoQuad : ao;

        ao = pow(saturate(ao), _Power);

        // 遠景ではサンプル間隔に対して深度差が粗くなるためフェードアウトさせる
        float fadeLength = max(_FadeDistance * 0.25, 1e-3);
        float fade = saturate((_FadeDistance - depth) / fadeLength);

        half strength = _Strength * fade * sd.mask[_MaskChannel];
        ao = saturate(lerp(1, ao, strength));

        half3 aoColor = lerp(_AOColor.rgb, half3(1,1,1), ao);
        sd.lightColor *= aoColor;
    }
}

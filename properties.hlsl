SC_uint(_Enable, 0, [SCInHeader][SCToggle][SCConstValue(1,pixel)], "", "")
SC_float(_Strength, 1.0, [SCRange(0,2)], "Strength", "")
SC_float(_Radius, 0.1, [SCRange(0.01,1)], "Radius", "")
SC_float(_Power, 1.5, [SCRange(0.5,8)], "Power", "")
SC_color(_AOColor, (0,0,0,1), [], "AO Color", "")
SC_Box
SC_uint(_Quality, 1, [SCEnum(Low,0,Medium,1,High,2,Ultra,3)][SCConstValue(4,pixel)], "Quality", "")
SC_uint(_Denoise, 1, [SCToggle][SCConstValue(1,pixel)], "Denoise", "")
SC_float(_Bias, 0.02, [SCRange(0,0.2)], "Bias", "")
SC_float(_FadeDistance, 15.0, [SCRange(1,50)], "Fade Distance", "")
SC_float(_MaxRadiusPixels, 64.0, [SCRange(16,256)], "Max Radius (px)", "")
SC_uint(_DisableInMirror, 1, [SCToggle], "Disable in Mirror", "")
SC_BoxEnd
SC_uint(_MaskChannel, 3, [SCMaskChannel], "__MaskChannel", "")

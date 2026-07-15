// VRChatがランタイムで設定するグローバル変数。シェーダー本体(NonToon/Shader-Core)は宣言していないため、
// 使う側のモジュールで宣言する必要がある。他モジュールと二重宣言にならないようガードする
#ifndef SC_VRCHAT_MIRROR_MODE_DECLARED
#define SC_VRCHAT_MIRROR_MODE_DECLARED
float _VRChatMirrorMode;
#endif

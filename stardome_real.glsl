#version 450
#pragma tweak_shader(version="1.0")

// ============================================================
// stardome_real.glsl — 超遠景「本物の空」(point3版 / StarFieldフォーク専用)
// 地球から見た実際の星 (Hipparcos 117,955 星) と実写の天の川 (NASA SVS Deep Star Maps 2020) を
// 2 枚の全天の画像 (8192x4096・正距円筒) で受け取り、カメラの姿勢と画角に追従して描く。視差ゼロ・ブラー無し。
// 2026-10-24 Mac Elena (7 月の stardome_catalog.glsl を StarField 向けに作り直した版)
//   - 星は画像の 1 画素 = 1 星。画素の中心に解析的なガウスの点を描く＝どの画角でも星が甘くならない (7 月版はテクスチャをそのまま拡大＝ピンぼけ)
//   - 星の地図の画素 = 等級と色 (catalog/bake_hipparcos_v2.py)。いちばん大きいチャンネル e → 等級・RGB ÷ e → 色
//   - 天の川 = catalog/milkyway_8k.png (catalog/bake_milkyway_8k.py)。値の 2.2 乗 × MW_REF が線形の明るさ
//   - 向き: view_ra / view_dec の空がカメラの既定の正面 (ワールド +Z) に来る・天の北が上・東が左 (7 月版は左右が逆だった)
//     view_roll = 空を画面の上で回す (+ = 反時計回り)
//   - 明るさ: 6 等の星 = 0.5 × brightness。contrast = 星の明るさの差の詰め方 (1 = 実際の比 / 小さいほど暗い星が見える)
//     milkyway = 天の川の強さ・mw_black = 天の川の画像の暗い所 (暗い星の積算のざらつき) を沈める量・mw_contrast = 天の川の階調
//     bloom = 明るい星ほど大きく描く強さ。星は aa ピクセルより細くしない (広げた分だけ暗く＝光の量は同じ)
//
// AE側:
//   - catalog/hipparcos_starmap_8k.png と catalog/milkyway_8k.png をフッテージとしてコンポに置き (目玉オフ)
//     「Is Image Filter」をオフにして star_map・mw_map に指定 (StarField_Setup_v2.jsx v2.5 が自動で行う)
//   - focal / cam_right / cam_up / cam_fwd は stardome_v7 と同じ expression 配線
//   - 🔴 画像は「フル画質」で 8192x4096 のまま渡ること。プレビューの解像度を 1/2 にすると AE が画像を縮めて渡す (星は補正して描くが近似)
// 注: point3入力・2 枚の image 入力は StarFieldフォーク(v0.1.2+)専用。本家TweakShaderでは読めない
//
// Credits:
//   - 星データ: The Hipparcos and Tycho Catalogues, ESA SP-1200 (1997) (ESA Hipparcosミッション / 配布=CDS VizieR I/239)
//   - 天の川: NASA/Goddard Space Flight Center Scientific Visualization Studio, Deep Star Maps 2020 (パブリックドメイン)
//             Gaia DR2: ESA/Gaia/DPAC
// ============================================================

#pragma utility_block(ShaderInputs)
layout(push_constant) uniform ShaderInputs {
    float time;
    float time_delta;
    float frame_rate;
    uint frame_index;
    vec4 mouse;
    vec4 date;
    vec3 resolution;
    uint pass_index;
};

layout(location = 0) out vec4 out_color;

#pragma input(float, name=brightness, default=1.0, min=0.0, max=8.0)
#pragma input(float, name=mag_limit, default=12.0, min=0.0, max=14.5)
#pragma input(float, name=contrast, default=0.7, min=0.2, max=1.0)
#pragma input(float, name=star_size, default=1.0, min=0.2, max=4.0)
#pragma input(float, name=bloom, default=1.0, min=0.0, max=3.0)
#pragma input(float, name=saturation, default=1.0, min=0.0, max=2.0)
#pragma input(float, name=aa, default=1.0, min=0.0, max=4.0)
#pragma input(float, name=milkyway, default=1.0, min=0.0, max=4.0)
#pragma input(float, name=mw_contrast, default=0.6, min=0.3, max=2.0)
#pragma input(float, name=mw_black, default=0.05, min=0.0, max=0.9)
#pragma input(float, name=view_ra, default=5.6, min=0.0, max=24.0)
#pragma input(float, name=view_dec, default=0.0, min=-90.0, max=90.0)
#pragma input(float, name=view_roll, default=0.0, min=-180.0, max=180.0)
// ---- 以下はカメラ配線系 (expression駆動・手では触らない) ----
#pragma input(float, name=focal, default=1.5, min=0.1, max=10.0)
#pragma input(point3, name=cam_right, default=[1.0, 0.0, 0.0])
#pragma input(point3, name=cam_up, default=[0.0, 1.0, 0.0])
#pragma input(point3, name=cam_fwd, default=[0.0, 0.0, 1.0])
#pragma input(color, name=tint, default=[1.0, 1.0, 1.0, 1.0])
layout(set = 0, binding = 1) uniform CustomInput {
    float brightness;
    float mag_limit;
    float contrast;
    float star_size;
    float bloom;
    float saturation;
    float aa;
    float milkyway;
    float mw_contrast;
    float mw_black;
    float view_ra;
    float view_dec;
    float view_roll;
    float focal;
    vec3  cam_right;
    vec3  cam_up;
    vec3  cam_fwd;
    vec4  tint;
};

#pragma sampler(name="linear_sampler", linear)
layout(set = 0, binding = 2) uniform sampler linear_sampler;

#pragma input(image, name="star_map")
layout(set = 0, binding = 3) uniform texture2D star_map;

#pragma input(image, name="mw_map")
layout(set = 0, binding = 4) uniform texture2D mw_map;

const float PI = 3.14159265358979;
// 星の地図の詰め方 (bake_hipparcos_v2.py と同じにする)
const float MAG_BRIGHT = -1.5;
const float MAG_RANGE = 16.0;
const float STAR_MAP_W = 8192.0;   // 焼いた幅。これより小さく渡されたら (プレビューの解像度 1/2 など) e を面積の比で戻す
// 天の川の詰め方 (bake_milkyway_8k.py と同じにする)
const float MW_REF = 0.27;
const float MW_NORM = 0.064;       // 天の川の明るい所 (全天の 99% 点) = 1 にそろえる
const float MW_GAIN = 0.2;         // milkyway 1・brightness 1 の時の天の川の明るい所の明るさ
const float STAR_REF = 0.5;        // brightness 1 の時の 6 等の星の芯の明るさ (contrast 0.7 で 4 等より明るい星は白く飽和・12 等で 2/255)
const float MW_SAT = 0.6;          // 天の川の色の濃さ (saturation 1 の時)。NASA の地図の色は画素ごとにばらつく＝薄めて使う
const vec3 Y709 = vec3(0.2126, 0.7152, 0.0722);

vec3 eq_dir(float ra, float dec) {
    float c = cos(dec);
    return vec3(c * cos(ra), c * sin(ra), sin(dec));
}

// 6 等 = STAR_REF × brightness の明るさ (contrast で差を詰める)
float star_lum(float mag) {
    return brightness * STAR_REF * exp2(-0.4 * (mag - 6.0) * contrast * 3.3219281);
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * resolution.xy) / resolution.y;

    // ---- 向き: ワールド → 赤道座標 (x = 赤経 0h・y = 赤経 6h・z = 天の北極) ----
    float vra = view_ra * PI / 12.0;
    float vdec = radians(view_dec);
    float vroll = radians(view_roll);
    vec3 f = eq_dir(vra, vdec);
    vec3 east = vec3(-sin(vra), cos(vra), 0.0);
    vec3 up = cross(f, east);
    float cr = cos(vroll), sr = sin(vroll);
    vec3 e2 = cr * east + sr * up;
    vec3 u2 = cr * up - sr * east;
    mat3 W2E = mat3(-e2, -u2, f);                        // AE のワールド (右 +X・下 +Y・奥 +Z) → 赤道座標。画面の右 = 西
    mat3 C2E = W2E * mat3(cam_right, cam_up, cam_fwd);   // カメラ → 赤道座標
    mat3 E2C = transpose(C2E);

    vec3 d = C2E * normalize(vec3(uv, focal));
    float ra = atan(d.y, d.x);
    float dec = asin(clamp(d.z, -1.0, 1.0));
    float mu = fract(0.5 - ra / (2.0 * PI));             // 画像の横 (中心 = 赤経 0h・左ほど赤経が大きい)
    float mv = 0.5 - dec / PI;                           // 画像の縦 (上 = 天の北極)

    vec3 col = vec3(0.0);

    // ---- 天の川 (実写・双一次・赤経の継ぎ目なし) ----
    ivec2 ms = textureSize(sampler2D(mw_map, linear_sampler), 0);
    if (ms.x >= 64 && milkyway > 0.0) {
        float mx = mu * float(ms.x) - 0.5;
        float my = clamp(mv * float(ms.y) - 0.5, 0.0, float(ms.y) - 1.0);
        int x0 = int(floor(mx));
        int y0 = int(floor(my));
        float tx = mx - float(x0);
        float ty = my - float(y0);
        int xa = (x0 + ms.x) % ms.x;                    // 🔴 負の数の % は GLSL では未定義＝足してから割る
        int xb = (xa + 1) % ms.x;
        int yb = min(y0 + 1, ms.y - 1);
        // 🔴 画像の読み出しは 1 行に 1 つ・関数の中に入れない (プラグインの前処理は pow(texelFetch(...)) の中の読み出しに
        //    AE の ARGB → RGBA の並べ替えを掛けない＝アルファが赤に出る。2026-10-24 真っ赤になった)
        vec4 k00 = texelFetch(sampler2D(mw_map, linear_sampler), ivec2(xa, y0), 0);
        vec4 k10 = texelFetch(sampler2D(mw_map, linear_sampler), ivec2(xb, y0), 0);
        vec4 k01 = texelFetch(sampler2D(mw_map, linear_sampler), ivec2(xa, yb), 0);
        vec4 k11 = texelFetch(sampler2D(mw_map, linear_sampler), ivec2(xb, yb), 0);
        vec3 m00 = pow(k00.rgb, vec3(2.2));
        vec3 m10 = pow(k10.rgb, vec3(2.2));
        vec3 m01 = pow(k01.rgb, vec3(2.2));
        vec3 m11 = pow(k11.rgb, vec3(2.2));
        vec3 m = mix(mix(m00, m10, tx), mix(m01, m11, tx), ty) * (MW_REF / MW_NORM);
        float ym = dot(m, Y709);
        float lm = pow(max(ym - mw_black, 0.0) / (1.0 - mw_black), mw_contrast) * milkyway * MW_GAIN * brightness;
        vec3 mc = mix(vec3(1.0), m / max(ym, 1e-6), saturation * MW_SAT);
        mc = mix(mc, vec3(1.0), smoothstep(0.4, 1.0, lm));  // 明るい所は白へ (1 つのチャンネルだけ頭打ちになって色がずれないように)
        col += max(mc, 0.0) * lm;
    }

    // ---- 星 (画素の中心に点を描く) ----
    ivec2 ts = textureSize(sampler2D(star_map, linear_sampler), 0);
    if (ts.x >= 64 && brightness > 0.0) {
        float Wt = float(ts.x), Ht = float(ts.y);
        float ecomp = (STAR_MAP_W / Wt) * (STAR_MAP_W / Wt);
        float px = 1.0 / resolution.y;
        float sig_aa = 0.5 * aa * px;
        float sig_s = 0.45 * star_size * px;
        // いちばん明るい星 (シリウス) が広がる半径 = 探す範囲
        float lmax = star_lum(MAG_BRIGHT);
        float sig_max = max(sig_s * (1.0 + bloom * 0.5 * log2(max(lmax, 1.0))), sig_aa);
        float R = min(4.5 * sig_max, 48.0 * px);
        float dtex = PI / Ht;                            // 1 画素の角度 (縦。横は赤道で同じ)
        float rang = R / focal;                          // 画面の中心での角度 (端ほど小さい＝多めに探す)
        float rr = rang / dtex;
        float fx = mu * Wt, fy = mv * Ht;
        int r0 = max(int(floor(fy - 0.5 - rr)), 0);
        int r1 = min(int(ceil(fy - 0.5 + rr)), ts.y - 1);
        float srang = sin(min(rang, 1.5));
        for (int row = r0; row <= r1; row++) {
            float sdec = 0.5 * PI - (float(row) + 0.5) * dtex;
            float cedge = cos(min(abs(sdec) + 0.5 * dtex, 0.5 * PI));
            int c0, c1;
            if (cedge <= srang) {
                c0 = 0; c1 = ts.x - 1;                   // 極の近く: 行を全部見る
            } else {
                float cw = asin(srang / cedge) / (2.0 * PI) * Wt;
                c0 = int(floor(fx - 0.5 - cw));
                c1 = int(ceil(fx - 0.5 + cw));
                if (c1 - c0 + 1 >= ts.x) { c0 = 0; c1 = ts.x - 1; }
            }
            for (int c = c0; c <= c1; c++) {
                int ci = (c + 2 * ts.x) % ts.x;                 // c は -幅 より大きい
                vec4 tk = texelFetch(sampler2D(star_map, linear_sampler), ivec2(ci, row), 0);
                vec3 t = tk.rgb;
                float e = max(t.r, max(t.g, t.b));
                if (e < 0.5 / 255.0) continue;
                float mag = MAG_BRIGHT + (1.0 - min(e * ecomp, 1.0)) * MAG_RANGE;
                if (mag > mag_limit + 0.5) continue;
                float sra = (0.5 - (float(ci) + 0.5) / Wt) * 2.0 * PI;
                vec3 q = E2C * eq_dir(sra, sdec);
                if (q.z < 0.02) continue;
                vec2 s = q.xy / q.z * focal;
                vec2 dv = uv - s;
                float dd2 = dot(dv, dv);
                if (dd2 > R * R) continue;
                float L = star_lum(mag) * (1.0 - smoothstep(mag_limit - 0.5, mag_limit + 0.5, mag));
                float sg = sig_s * (1.0 + bloom * 0.5 * log2(max(L, 1.0)));
                float sw = max(sg, sig_aa);
                float amp = L * (sg * sg) / (sw * sw);
                vec3 chroma = t / e;
                chroma /= max(dot(chroma, Y709), 1e-4);
                vec3 sc = max(mix(vec3(1.0), chroma, saturation), 0.0);
                float win = 1.0 - smoothstep(0.7 * R * R, R * R, dd2);
                col += sc * amp * exp(-dd2 / (2.0 * sw * sw)) * win;
            }
        }
    }

    col *= tint.rgb;
    // 最下層(背景)前提の不透明出力
    out_color = vec4(col, 1.0);
}

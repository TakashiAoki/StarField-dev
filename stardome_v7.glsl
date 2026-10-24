#version 450
#pragma tweak_shader(version="1.0")

// ============================================================
// stardome_v7.glsl — 超遠景プロシージャル天球 (point3版 / StarFieldフォーク専用)
// 無限遠の星: 視差ゼロ・モーションブラー無し。カメラの姿勢と画角のみ追従。
// StarPro的な要点の再現:
//   - べき乗則の等級分布 (粗いオクターブ=明るく希少 / 細かい=暗く大量)
//   - 黒体放射近似の星色 (青白〜橙赤、白寄り分布)
//   - 天の川バンド (暗い星の密度変調 + 雲状ヘイズ)
// v7 (2026-10-24 Mac Elena): 天の川を実写の全天マップの測定に合わせた (MILKYWAY_REFERENCE.md)
//   - 緯度の形 = 芯 + 広い裾 (芯の 0.22 倍・幅 2.9 倍)。mw_width 0.22 で実写の幅 (芯の 1/e 半幅 約 12°)
//   - 帯に沿った明るさ = 中心 (帯の経度 0) ほど明るい + 10〜20° の星の雲の起伏
//   - 暗黒帯 = 芯の北寄りの濃い層 + 帯の外へ張り出す雲。2 段のフラクタルにしきい値 → 減光 τ → 透過 exp(-τ)
//     (v6 の「帯に沿った細い筋 + 1 本の裂け目」をやめた。実写は 0.5〜3° の塊が集まった層)
//   - 明るい星ほど広く薄く・暗い星ほど細く濃く天の川に集まる (Hipparcos で明るい星の 天の川/極 = 約 2.2)
//   - 雲の色 = 実写の傾向 (中心は暖色・暗黒帯の縁は赤み・裾は白〜青白)。MW_REAL_COLOR = 0 で v6 の色に戻る
//   - 入力の並びは v5/v6 と同じ (パラメーター番号・Setup・見本の値がそのまま使える)
//   - 採用 (2026-10-24): MW_STARCLOUD = 1 のまま。見本 SF03 は彩色を弱めた (Exposure +2.8・Glow 半径 120)
// v6 (2026-10-24 Mac Elena): 天の川の雲を作り直した (1 本につながった帯と暗黒帯)
//   - 解析的ガウス点描画 (サブピクセル・ジャギー無し)
// 2026-07-02 Win Elena
//
// AE側expression配線 (4本のみ・位置/速度は不要):
//   focal = thisComp.activeCamera.zoom / thisComp.height
//   cam_right/cam_up/cam_fwd = toWorldVec([1,0,0]) / [0,1,0] / [0,0,1]
// 注: point3入力はStarFieldフォーク(v0.1.2+)専用。本家TweakShaderでは読めない
// 🔴 雲の式を直したら tools/mw_cloud.py の cloud_v7 も同じに直す (numpy の写し・測定と絵の試作に使う)
// Credits:
//   - hash関数: "Hash without Sine" by David Hoskins (MIT)
//     https://www.shadertoy.com/view/4djSRW
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

#pragma input(float, name=density, default=1.0, min=0.1, max=2.0)
#pragma input(float, name=star_size, default=1.0, min=0.2, max=4.0)
#pragma input(float, name=brightness, default=1.0, min=0.0, max=4.0)
#pragma input(float, name=dim_boost, default=1.0, min=0.2, max=3.0)
#pragma input(float, name=milkyway, default=0.6, min=0.0, max=1.0)
#pragma input(float, name=mw_yaw, default=35.0, min=-180.0, max=180.0)
#pragma input(float, name=mw_pitch, default=55.0, min=-90.0, max=90.0)
#pragma input(float, name=mw_width, default=0.35, min=0.05, max=1.0)
#pragma input(float, name=haze, default=1.0, min=0.0, max=3.0)
#pragma input(float, name=seed, default=0.0, min=0.0, max=100.0)
#pragma input(float, name=aa, default=1.0, min=0.0, max=4.0)
// ---- 以下はカメラ配線系 (expression駆動・手では触らない) ----
#pragma input(float, name=focal, default=1.5, min=0.1, max=10.0)
#pragma input(point3, name=cam_right, default=[1.0, 0.0, 0.0])
#pragma input(point3, name=cam_up, default=[0.0, 1.0, 0.0])
#pragma input(point3, name=cam_fwd, default=[0.0, 0.0, 1.0])
#pragma input(color, name=tint, default=[0.9, 0.95, 1.0, 1.0])
layout(set = 0, binding = 1) uniform CustomInput {
    float density;
    float star_size;
    float brightness;
    float dim_boost;
    float milkyway;
    float mw_yaw;
    float mw_pitch;
    float mw_width;
    float haze;
    float seed;
    float aa;
    float focal;
    vec3  cam_right;
    vec3  cam_up;
    vec3  cam_fwd;
    vec4  tint;
};

// 雲の色: 1 = 実写の傾向 (v7) / 0 = v6 の青白一色。明るさ (Rec.709 の輝度) はどちらも同じ
const float MW_REAL_COLOR = 1.0;
// 星の雲の起伏: 1 = 実写の測定どおり (10〜20° の明暗の塊) / 0 = v6 並みのなめらかに続く芯 (強い露出＋グローで塊が玉に見える時)
const float MW_STARCLOUD = 1.0;

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

float hash13(vec3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

// 3D値ノイズ (天の川ヘイズ用。方向ベクトル入力なので継ぎ目なし)
float vnoise3(vec3 p) {
    vec3 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash13(i);
    float n100 = hash13(i + vec3(1, 0, 0));
    float n010 = hash13(i + vec3(0, 1, 0));
    float n110 = hash13(i + vec3(1, 1, 0));
    float n001 = hash13(i + vec3(0, 0, 1));
    float n101 = hash13(i + vec3(1, 0, 1));
    float n011 = hash13(i + vec3(0, 1, 1));
    float n111 = hash13(i + vec3(1, 1, 1));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

// 八面体マッピング (方向 <-> 2D。天球のセル分割に使う)
vec2 octEncode(vec3 v) {
    v /= (abs(v.x) + abs(v.y) + abs(v.z));
    vec2 e = v.xy;
    if (v.z < 0.0) e = (1.0 - abs(vec2(v.y, v.x))) * vec2(v.x >= 0.0 ? 1.0 : -1.0, v.y >= 0.0 ? 1.0 : -1.0);
    return e * 0.5 + 0.5;
}

vec3 octDecode(vec2 f) {
    f = f * 2.0 - 1.0;
    vec3 v = vec3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
    if (v.z < 0.0) {
        vec2 s = vec2(v.x >= 0.0 ? 1.0 : -1.0, v.y >= 0.0 ? 1.0 : -1.0);
        v = vec3((1.0 - abs(v.y)) * s.x, (1.0 - abs(v.x)) * s.y, v.z);
    }
    return normalize(v);
}

// 値ノイズの重ね (v6)
float fbm(vec3 p, int oct) {
    float s = 0.0, a = 0.5, n = 0.0;
    for (int i = 0; i < 5; i++) {
        if (i >= oct) break;
        s += a * vnoise3(p); n += a;
        p = p * 2.03 + vec3(17.1, 9.3, 4.7); a *= 0.5;
    }
    return s / n;
}

// 黒体放射っぽい星色 (t=0 橙赤 → t=1 青白、白寄りに圧縮)
vec3 star_color(float t) {
    vec3 c = mix(vec3(1.0, 0.58, 0.32), vec3(0.68, 0.80, 1.0), pow(t, 0.6));
    return mix(vec3(1.0), c, 0.55);
}

// 色の明るさを v6 の雲の色 (0.75, 0.82, 1.0) と同じ輝度にそろえる
vec3 luma_match(vec3 c) {
    const vec3 Y = vec3(0.2126, 0.7152, 0.0722);
    return c * (dot(vec3(0.75, 0.82, 1.0), Y) / dot(c, Y));
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * resolution.xy) / resolution.y;

    mat3 M = mat3(cam_right, cam_up, cam_fwd);
    mat3 Mi = transpose(M);
    vec3 dir = M * normalize(vec3(uv, focal));

    // ---- 天の川 (v7): 実写の全天マップの測定に合わせた帯 (MILKYWAY_REFERENCE.md) ----
    float cy = cos(radians(mw_yaw)), sy = sin(radians(mw_yaw));
    float cp = cos(radians(mw_pitch)), sp = sin(radians(mw_pitch));
    vec3 bn = normalize(vec3(sy * cp, sp, cy * cp));                  // 帯の面の法線 (v5 と同じ)
    vec3 e1 = normalize(cross(bn, abs(bn.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
    vec3 e2 = cross(bn, e1);                                           // e1・e2 = 帯の面
    float gl = atan(dot(dir, e2), dot(dir, e1));                       // 帯に沿った角度 (銀経相当・0 = 中心)
    vec3 q = vec3(cos(gl), sin(gl), 0.0);                              // 銀経を円に置く＝継ぎ目なし
    float wob = (vnoise3(q * 1.7 + vec3(seed * 0.37, 0.0, 3.1)) - 0.5) * mw_width * 0.3;
    float bt = (dot(dir, bn) - wob) / mw_width;                        // 波打つ中心線からの距離 (帯幅単位)
    // 緯度の形: 芯 + 広い裾 (実写: 芯 1/e 半幅 12°・裾 = 芯の約 0.2 倍で幅約 3 倍・裾は v6 より強く狭い)
    float bc = bt / 0.84, bh = bt / 2.4;                               // 🔴 二乗は掛け算で (pow は負の底が未定義)
    float band = exp(-bc * bc);
    float halo = exp(-bh * bh);
    // 帯に沿った明るさ: 中心ほど明るい (反対側で 0.4 倍) + 10〜20° の星の雲の起伏 (60° の窓で最大/最小 約 3 倍)
    float cen = 0.5 + 0.5 * cos(gl);
    float env = 0.4 + 0.6 * pow(cen, 1.5);
    float big = exp(1.2 * MW_STARCLOUD * (fbm(vec3(q.xy * 3.5, bt * 1.2) + vec3(seed * 0.61 + 41.0), 4) - 0.5) * 4.0);
    // 暗黒帯: 緯度の密度 (芯の北寄りの濃い層 + 帯の外へ張り出す雲) × 2 段のフラクタル → 減光 τ → 透過 exp(-τ)
    vec3 pd = vec3(q.xy * 12.0, bt * 4.0) + seed * 1.31;
    float wv = vnoise3(pd * 0.37 + vec3(3.1)) - 0.5;
    pd += 0.6 * vec3(wv, -wv, wv * 0.5) * 2.0;                        // 塊の並びをゆがめる (向きを散らす)
    float rwin = 0.45 + 0.55 * (1.0 - smoothstep(0.5, 1.25, abs(gl))); // 濃い層は中心の前後 ±70° ほど (大裂け目相当)
    float layC = 0.45 + (vnoise3(q * 2.3 + vec3(seed * 0.5 + 7.0)) - 0.5) * 0.3;
    float bl = (bt - layC) / 0.38, bo = bt / 1.4;
    float lay = exp(-bl * bl) * rwin;
    float off = exp(-bo * bo) * 0.5 * (0.4 + 0.6 * vnoise3(q * 1.9 + vec3(seed * 0.7 + 13.0)));
    float prob = max(lay, off);
    float dn = 0.55 * fbm(pd * 0.45, 4) + 0.45 * fbm(pd * 1.6 + vec3(5.0), 4);
    float th = 0.60 - 0.22 * prob;
    float tau = prob * max(dn - th, 0.0) / 0.10;
    float dust = clamp(1.0 - exp(-tau), 0.0, 0.95);
    // 星の雲のまだら + 細かいつぶつぶ
    float cl = smoothstep(0.25, 0.85, fbm(vec3(q.xy * mix(4.0, 6.0, MW_STARCLOUD), bt * mix(3.0, 1.6, MW_STARCLOUD)) + vec3(seed * 2.7 + 31.0), 5)); // 0 = v6 と同じ帯に沿った細長いまだら
    float grain = fbm(dir * 40.0 + vec3(seed * 3.3 + 57.0), 3);
    float mw = band * (0.35 + 1.1 * cl) * env * big * (0.7 + 0.6 * grain) * (1.0 - dust); // 雲の明るさ (0〜約 2)
    float mw_star = clamp(band * (0.45 + 0.8 * cl) * (1.0 - dust * 0.85), 0.0, 1.0); // 暗い星の密度変調 (細く濃い)
    float bw = dot(dir, bn) / mw_width / 1.9;
    float mw_wide = exp(-bw * bw);                                     // 明るい星の密度変調 (広く薄い)

    vec3 col = vec3(0.0);

    // 等級オクターブ: 粗い=明るく希少 / 細かい=暗く大量 (べき乗則近似)
    // N=24*2^o (天球セル分割数), amp=0.42^o (輝度), prob=0.35+0.1*o (存在確率)
    const int OCTAVES = 4;
    vec2 ouv = octEncode(dir);

    for (int o = 0; o < OCTAVES; o++) {
        float fo = float(o);
        float N = 24.0 * exp2(fo);
        vec2 cellf = ouv * N;
        vec2 base_id = floor(cellf);
        float amp = pow(0.42, fo) * ((o >= 2) ? dim_boost : 1.0);
        float sprob = 0.35 + 0.1 * fo;

        // 明るいオクターブほど広く薄く (天の川/極 約 2.2)・暗いほど細く濃く (約 4.6 = v6 と同じ) 集まる
        float wm = fo / float(OCTAVES - 1);
        float mw_dens = mix(1.0, mix(mix(0.68, 0.35, wm), mix(1.5, 1.6, wm), mix(mw_wide, mw_star, wm)), milkyway);

        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                vec2 id = base_id + vec2(float(dx), float(dy));
                if (id.x < 0.0 || id.y < 0.0 || id.x >= N || id.y >= N) continue;
                vec2 sd = id + vec2(float(o) * 37.61, seed * 7.77);
                float ex = hash12(sd + 5.5);
                if (ex > sprob * density * mw_dens) continue;

                vec2 rnd = hash22(sd);
                vec3 sdir = octDecode((id + rnd) / N);

                // カメラ空間へ投影 (無限遠: 方向のみ)
                vec3 qs = Mi * sdir;
                if (qs.z < 0.02) continue;
                vec2 s = qs.xy / qs.z * focal;
                float d = length(uv - s);

                // 等級ジッター (同オクターブ内でも輝度に幅を持たせる)
                float mag = 0.3 + 0.7 * pow(hash12(sd + 9.1), 2.0);
                float sz = star_size * 0.0016 * (0.6 + 0.8 * hash12(sd + 3.3));
                // 解析的AA (エネルギー保存): 最小点径をaaピクセルで確保し、広げた分だけ暗く
                float px = 1.0 / resolution.y;
                float base_w = 0.6 * px;
                float w = max(base_w, aa * px);
                float d_eff = sqrt(d * d + w * w);
                float glow = sz / max(d_eff, 1e-5);
                glow = glow * glow * 0.30; // 点は積分が幅に鈍感でないため無正規化で十分
                float lum = min(glow, 6.0) * amp * mag;

                col += star_color(hash12(sd + 1.7)) * lum;
            }
        }
    }

    // 天の川の雲 (v7): 帯 + 裾。暗黒帯で暗くなる
    if (milkyway > 0.001 && haze > 0.001) {
        float hl = halo * 0.22 * env * (0.85 + 0.15 * big) * (1.0 - dust * 0.5);
        float h = mw + hl;
        // 実写の色の傾向: 星の雲 = 暖かい白 (B-V 約 0.7)・中心 = より暖色・暗黒帯の縁 = 赤み (減光で青が先に減る)・裾 = 白〜青白
        vec3 cc = mix(vec3(1.0, 0.95, 0.90), vec3(0.93, 0.96, 1.0), hl / max(h, 1e-4));
        cc = mix(cc, vec3(1.0, 0.88, 0.74), pow(cen, 4.0) * band * 0.6);
        cc = mix(cc, vec3(1.0, 0.80, 0.64), clamp(4.0 * dust * (1.0 - dust), 0.0, 1.0) * 0.7);
        vec3 mwc = mix(vec3(0.75, 0.82, 1.0), luma_match(cc), MW_REAL_COLOR);
        col += mwc * h * milkyway * haze * 0.02;
    }

    col *= brightness * tint.rgb;
    // 最下層(背景)前提の不透明出力。微小アルファはアンプリマルチで白飛びするため使わない
    out_color = vec4(col, 1.0);
}

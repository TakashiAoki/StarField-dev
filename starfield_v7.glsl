#version 450
#pragma tweak_shader(version="1.0")

// ============================================================
// starfield_v7.glsl — 星間航行パーティクル (StarFieldフォーク版・point3対応)
// AE 3Dカメラ完全連動版: 位置(XYZ)・姿勢(3x3行列)・画角(zoom)を
// expressionから受け取り、厳密なレイ投影でレンダリングする。
// 消失点はカメラの向きに正しく追従する。
// 2026-07-02 Win Elena
//
// 座標系: AEワールド座標そのまま (x右 / y下 / z奥)。単位は AEpx * 0.01
//
// AE側expression配線 (jsx/routeD_camera_link_v2.jsx が自動設定):
//   focal  = thisComp.activeCamera.zoom / thisComp.height
//   cam_*  = thisComp.activeCamera.toWorld([0,0,0]) * 0.01
//   vel_*  = カメラ位置の1フレーム差分 / frameDuration * 0.01
//   r*/u*/f* = toWorldVec([1,0,0]) / [0,1,0] / [0,0,1]  (姿勢行列)
// Credits:
//   - アルゴリズム移植元: CodePen "Particles Stream" by sabosugi (MIT)
//     https://codepen.io/sabosugi/pen/yygMKRb
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

#pragma input(float, name=density, default=1.0, min=0.1, max=4.0)
#pragma input(float, name=star_size, default=1.0, min=0.1, max=5.0)
#pragma input(float, name=streak, default=0.5, min=0.0, max=1.0)
#pragma input(float, name=brightness, default=1.0, min=0.0, max=4.0)
#pragma input(float, name=near_fade, default=2.5, min=0.5, max=30.0)
#pragma input(float, name=near_soft, default=1.5, min=0.1, max=10.0)
#pragma input(float, name=far_fade, default=48.0, min=8.0, max=48.0)
#pragma input(float, name=far_soft, default=14.0, min=1.0, max=40.0)
#pragma input(float, name=color_var, default=1.0, min=0.0, max=2.0)
#pragma input(float, name=tail_fade, default=0.65, min=0.0, max=1.0)
#pragma input(float, name=tail_sharp, default=2.0, min=0.3, max=6.0)
#pragma input(float, name=aa, default=1.5, min=0.0, max=4.0)
// ---- 以下はカメラ配線系 (expression駆動・手では触らない) ----
// point3型 = StarFieldフォーク版プラグイン専用 (AE 3D Pointパラメータ・expression1本で[x,y,z])
#pragma input(float, name=focal, default=1.5, min=0.1, max=10.0)
#pragma input(point3, name=cam, default=[6.4, 3.6, 0.0])
#pragma input(point3, name=vel, default=[0.0, 0.0, 6.0])
#pragma input(point3, name=cam_right, default=[1.0, 0.0, 0.0])
#pragma input(point3, name=cam_up, default=[0.0, 1.0, 0.0])
#pragma input(point3, name=cam_fwd, default=[0.0, 0.0, 1.0])
#pragma input(color, name=tint, default=[0.75, 0.85, 1.0, 1.0])
layout(set = 0, binding = 1) uniform CustomInput {
    float density;
    float star_size;
    float streak;
    float brightness;
    float near_fade;
    float near_soft;
    float far_fade;
    float far_soft;
    float color_var;
    float tail_fade;
    float tail_sharp;
    float aa;
    float focal;
    vec3  cam;       // カメラワールド位置 (AEpx*0.01)
    vec3  vel;       // カメラ速度 (unit/sec)
    vec3  cam_right; // 姿勢行列列ベクトル
    vec3  cam_up;
    vec3  cam_fwd;
    vec4  tint;
};

// 星平面: SPACING間隔でワールドz方向に無限周期配置 (Zトレッドミル)
const int   LAYERS  = 48;
const float SPACING = 1.0;
const float DEPTH   = float(LAYERS) * SPACING;

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

// 点Pから線分ABまでの距離と、線分上の位置t (0=A端=先端 / 1=B端=尾)
vec2 seg_dist_t(vec2 P, vec2 A, vec2 B) {
    vec2 g = B - A;
    vec2 h = P - A;
    float t = clamp(dot(g, h) / max(dot(g, g), 1e-8), 0.0, 1.0);
    return vec2(length(h - g * t), t);
}

// 黒体放射っぽい恒星色 (tw=0 橙赤 → tw=1 青白)
vec3 star_temp_color(float tw) {
    return mix(vec3(1.0, 0.55, 0.30), vec3(0.65, 0.78, 1.0), pow(tw, 0.6));
}

void main() {
    // スクリーン座標 (y下向き=AE準拠、高さ正規化)
    vec2 uv = (gl_FragCoord.xy - 0.5 * resolution.xy) / resolution.y;

    // カメラ姿勢行列 (列=右/上/前方、カメラ→ワールド)
    mat3 M = mat3(cam_right, cam_up, cam_fwd);
    mat3 Mi = transpose(M); // 正規直交なので転置=逆行列 (ワールド→カメラ)

    // cam はuniformから直接
    // レイ方向 (ワールド空間)
    vec3 dir = M * normalize(vec3(uv, focal));

    // streak: シャッター開角相当の時間だけ前の露光開始位置から線を引く
    float shutter = streak / max(frame_rate, 1.0);
    vec3 cam_prev = cam - vel * shutter;

    float cell = 1.0 / density;
    vec3 col = vec3(0.0);

    if (abs(dir.z) > 0.02) {
        for (int i = 0; i < LAYERS; i++) {
            // カメラ前方(z+)の平面までの距離 (Zトレッドミル)
            float wz_rel = mod(float(i) * SPACING - cam.z, DEPTH);
            if (wz_rel < 0.05) continue;
            float plane_z = cam.z + wz_rel;
            // 星パターンはワールド平面インデックスに固定 (カメラが動いても星は動かない)
            float pidx = floor(plane_z / SPACING + 0.5);

            // レイと平面の交点 (ワールドXY)
            float t = wz_rel / dir.z;
            if (t < 0.0) continue;
            vec2 hit = cam.xy + dir.xy * t;

            // 層ごとのグリッドオフセット (十字アーティファクト防止)
            vec2 grid_ofs = hash22(vec2(pidx * 13.7, pidx * 41.3)) * cell;
            vec2 gp = hit + grid_ofs;
            vec2 id = floor(gp / cell);

            vec2 seed = id + pidx * 71.37;
            vec2 rnd = hash22(seed);
            float h = hash12(seed + 17.17);
            if (h < 0.25) continue;

            // 星のワールド位置
            vec3 P = vec3((id + 0.2 + rnd * 0.6) * cell - grid_ofs, plane_z);

            // 露光開始/終了の2点をカメラ空間へ投影 → スクリーン線分
            vec3 q1 = Mi * (P - cam);
            vec3 q2 = Mi * (P - cam_prev);
            if (q1.z < 0.1 || q2.z < 0.1) continue;
            vec2 s1 = q1.xy / q1.z * focal;
            vec2 s2 = q2.xy / q2.z * focal;
            // s1=露光終了(現在)=先端 / s2=露光開始(過去)=尾
            vec2 dt = seg_dist_t(uv, s1, s2);
            float d = dt.x;

            float sz = star_size * (0.5 + h) * 0.0022;
            // 解析的AA (エネルギー保存): 最小線幅をaaピクセルで確保しつつ、
            // 幅を広げた分だけピーク輝度を下げる → サブピクセル線のちらつきを抑えつつ白飛びしない
            float px = 1.0 / resolution.y;
            float base_w = 0.6 * px;                 // 実効サブピクセル基準幅
            float w = max(base_w, aa * px);          // 強制最小半幅
            float d_eff = sqrt(d * d + w * w);
            float glow = sz / max(d_eff, 1e-5);
            // 線の断面 ∫sz²/(x²+w²)dx = sz²π/w なので ×(w/base) で積分エネルギー一定。
            // ピークは1/wで下がり幅はwに広がる = 理想的な解析的AA (aa=0で従来と同一)
            glow = glow * glow * 0.35 * (w / base_w);
            // 近傍フェードはカメラ空間距離q1.z基準 (Particular Near Fadeと同じ考え方)
            float fade = smoothstep(near_fade - near_soft, near_fade, q1.z)
                       * (1.0 - smoothstep(far_fade - far_soft, far_fade, wz_rel));
            // 残光グラデ: 先端(t=0)は白い点、尾(t=1)へ向けて減衰
            float tail_w = mix(1.0, pow(1.0 - dt.y, tail_sharp), tail_fade);
            float lum = min(glow, 4.0) * fade * tail_w / (1.0 + q1.z * q1.z * 0.02);

            // 恒星色のばらつき (color_var=0でtint一色)
            vec3 star_c = star_temp_color(hash12(seed + 2.3));
            vec3 c = tint.rgb * mix(vec3(1.0), star_c, min(color_var * 0.5, 1.0) + max(color_var - 1.0, 0.0) * 0.5);
            col += c * lum;
        }
    }

    col *= brightness;
    float alpha = clamp(max(col.r, max(col.g, col.b)), 0.0, 1.0);
    out_color = vec4(col, alpha);
}

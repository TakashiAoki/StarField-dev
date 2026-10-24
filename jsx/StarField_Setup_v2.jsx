// ============================================
// Script Name : StarField_Setup_v2.jsx
// Version     : v2.5
// 仕様        : 空コンポにStarField 3層(遠景/中景/近景)+3Dカメラをワンクリック生成
//               (StarFieldフォーク版プラグイン + サイドカー自動読込方式・テンプレaep不要)
// Copyright   : Over Ray Studio
// Author      : Takashi Aoki
// LastUpdate  : 2026-10-24
// ============================================
// 前提:
//   - StarField.aex v0.1.2以降 (サイドカー自動読込対応のフォーク版) が導入済みであること
//   - シェーダ: stardome_v7.glsl / starfield_v7.glsl / nearfield_v2.glsl / stardome_real.glsl (全てpoint3版・本スクリプトと同じae_starfield/に配置)
//   - 本物の空の画像: catalog/hipparcos_starmap_8k.png / catalog/milkyway_8k.png (ae_starfield/catalog/)
// 使い方:
//   - アクティブコンポで実行 → そのコンポに SF_cam / SF_near / SF_mid / SF_dome_real / SF_dome / SF_starmap / SF_mwmap を生成
//     (SF_dome_real・SF_starmap・SF_mwmap は目玉オフ。本物の空を使う時は SF_dome_real の目玉を入れる = 不透明なので SF_dome を覆う)
//   - コンポ未選択なら "StarField"(2048x1080/24fps/10s) を新規作成して生成
//   - デフォルトで「カメラがゆっくり前進」(カメラZ: +240px/s のexpression。キー打ちで自由に差し替え可)
// 仕組み:
//   - %TEMP%/starfield_load_request.txt にシェーダパスを書いてからStarFieldを適用すると
//     適用時(SequenceSetup)にプラグインが自動読込する。結果は starfield_load_result.txt (OK/ERR)
//   - パラメータはインデックス直指定 (動的param index = 7 + 8*入力順 + 型オフセット float=0/point3=7/color=5)
//     ※ECW表示名はUI描画後に反映されるが、インデックス設定はECW表示と無関係に機能する
// 注意:
//   - 対象コンポに既にSF_*レイヤーがある場合は二重生成を防ぐため中断する
//   - 旧TweakShader用の StarField_Setup.jsx (v1.4・テンプレ方式) とは独立。共存可
//   - v2.1: 失敗したら理由を alert で出す (自動実行から呼ぶ時は先に $.global.SF_SETUP_QUIET = true)
//           Mac はサイドカーを $TMPDIR 直下にも書く (Win は %TEMP% のみ・動きは v2.0 と同じ)
//   - v2.2: 近景の既定を「尾を引かない極小の粒＝カメラ近くの星間浮遊物」に (2026-10-23・見本の AEP で決めた値)
//           density 0.4→0.8・size 0.05→0.006・streak 0.15→0・brightness 0.6→2.6・range 14→20・near_fade 6.5→10・near_soft 1.5→2
//   - v2.3: 遠景を stardome_v6.glsl に (天の川の雲を 1 本につながった帯＋暗黒帯に作り直した版・入力の並びは v5 と同じ) (2026-10-24)
//   - v2.4: 遠景を stardome_v7.glsl に (天の川を実写の全天マップの測定に合わせた版・入力の並びは v5/v6 と同じ・MILKYWAY_REFERENCE.md) (2026-10-24)
//   - v2.5: 本物の空 SF_dome_real (stardome_real.glsl・Hipparcos の星＋NASA の実写の天の川) を目玉オフで追加 (2026-10-24)
//           画像 2 枚はフッテージ SF_starmap・SF_mwmap (目玉オフ) として置き、Is Image Filter をオフにして star_map・mw_map に指定する
//           画像はプロジェクトに読み込み済みなら使い回す (同じファイル)
(function () {
	var out = { comp: null, layers: [], loads: [], error: null, step: "start" };
	function fail(msg) { throw new Error(msg); }

	// --- シェーダパス解決 (このjsxの親=ae_starfield/) ---
	var shaderDir;
	try { shaderDir = File($.fileName).parent.parent.fsName; } catch (e0) { shaderDir = "C:/Users/takashi/Dropbox/AI_Workspace/ae_starfield"; }
	function shaderPath(name) {
		var f = new File(shaderDir + "/" + name);
		if (!f.exists) f = new File("C:/Users/takashi/Dropbox/AI_Workspace/ae_starfield/" + name);
		if (!f.exists) fail("シェーダが見つかりません: " + name);
		return f.fsName;
	}

	// --- 本物の空の画像 (プロジェクトに同じファイルがあれば使い回す) ---
	function mapFootage(name) {
		var f = new File(shaderDir + "/catalog/" + name);
		if (!f.exists) fail("画像が見つかりません: catalog/" + name);
		for (var i = 1; i <= app.project.numItems; i++) {
			var it = app.project.item(i);
			if (it instanceof FootageItem && it.file && it.file.fsName === f.fsName) return it;
		}
		return app.project.importFile(new ImportOptions(f));
	}

	// --- サイドカー読込つきエフェクト適用 ---
	// Win = %TEMP% (Folder.temp と同じ) / Mac = $TMPDIR 直下 (Folder.temp は .../T/TemporaryItems でプラグインの見る場所とずれる)
	var tmpDirList = [Folder.temp.fsName];
	try { var envTmp = $.getenv("TMPDIR"); if (envTmp) tmpDirList.unshift(envTmp.replace(/\/+$/, "")); } catch (eT) {}
	function tmpFileList(name) {
		var l = [];
		for (var i = 0; i < tmpDirList.length; i++) l.push(new File(tmpDirList[i] + "/" + name));
		return l;
	}
	var sidecarList = tmpFileList("starfield_load_request.txt");
	var resultList = tmpFileList("starfield_load_result.txt");
	function applyStarField(layer, glslPath) {
		for (var r = 0; r < resultList.length; r++) { if (resultList[r].exists) resultList[r].remove(); }
		for (var s = 0; s < sidecarList.length; s++) {
			var sc = sidecarList[s];
			sc.encoding = "UTF-8"; sc.open("w"); sc.write(glslPath); sc.close();
		}
		var fx;
		try {
			fx = layer.property("ADBE Effect Parade").addProperty("StarField");
		} finally {
			for (var s2 = 0; s2 < sidecarList.length; s2++) { try { if (sidecarList[s2].exists) sidecarList[s2].remove(); } catch (eS) {} }
		}
		var res = "NO_RESULT";
		for (var r2 = 0; r2 < resultList.length; r2++) {
			var rf = resultList[r2];
			if (rf.exists) { rf.encoding = "UTF-8"; rf.open("r"); res = rf.read(); rf.close(); break; }
		}
		out.loads.push(layer.name + ": " + res.substring(0, 60));
		if (res.indexOf("OK") !== 0) fail(layer.name + " のシェーダ読込に失敗: " + res);
		return fx;
	}

	// --- シェイプレイヤー生成 (コンポサイズ自動追従・expression固定) ---
	function makeShapeLayer(comp, name) {
		var sl = comp.layers.addShape();
		sl.name = name;
		var grp = sl.property("ADBE Root Vectors Group").addProperty("ADBE Vector Group");
		var vg = grp.property("ADBE Vectors Group");
		var rect = vg.addProperty("ADBE Vector Shape - Rect");
		rect.property("ADBE Vector Rect Size").expression = "[thisComp.width, thisComp.height]";
		rect.property("ADBE Vector Rect Position").expression = "[0, 0]";
		var fill = vg.addProperty("ADBE Vector Graphic - Fill");
		fill.property("ADBE Vector Fill Opacity").expression = "100";
		var tf = sl.property("ADBE Transform Group");
		tf.property("ADBE Position").expression = "[thisComp.width/2, thisComp.height/2]";
		tf.property("ADBE Scale").expression = "[100, 100]";
		return sl;
	}

	function setVals(fx, map) { for (var k in map) fx.property(parseInt(k, 10)).setValue(map[k]); }
	function setExprs(fx, map) { for (var k in map) fx.property(parseInt(k, 10)).expression = map[k]; }

	var C = "thisComp.activeCamera";
	var EXPR = {
		focal: C + ".zoom / thisComp.height",
		cam: C + ".toWorld([0,0,0]) * 0.01",
		vel: "var c = " + C + "; var dt = thisComp.frameDuration; var ts = Math.max(time, dt); (c.toWorld([0,0,0], ts) - c.toWorld([0,0,0], ts - dt)) * 0.01 / dt",
		right: C + ".toWorldVec([1,0,0])",
		up: C + ".toWorldVec([0,1,0])",
		fwd: C + ".toWorldVec([0,0,1])"
	};

	try {
		app.beginUndoGroup("StarField Setup v2");

		// --- 対象コンポ決定 ---
		out.step = "target";
		var target = app.project.activeItem;
		if (!(target && target instanceof CompItem)) {
			target = app.project.items.addComp("StarField", 2048, 1080, 1.0, 10, 24);
		}
		for (var L = 1; L <= target.numLayers; L++) {
			if (/^SF_(cam|near|mid|dome|dome_real|starmap|mwmap)$/.test(target.layer(L).name)) fail("SF_レイヤーが既に存在します(二重生成防止で中断)");
		}
		target.openInViewer();

		// --- 遠景: stardome_v7 (16入力: 12f + 3p3 + color・並びは v5/v6 と同じ) ---
		out.step = "dome";
		var dome = makeShapeLayer(target, "SF_dome");
		var fxD = applyStarField(dome, shaderPath("stardome_v7.glsl"));
		setVals(fxD, { 7: 1.0, 15: 1.0, 23: 1.0, 31: 1.0, 39: 0.6, 47: 35.0, 55: 55.0, 63: 0.35, 71: 1.0, 79: 0.0, 87: 1.0 });
		fxD.property(132).setValue([0.9, 0.95, 1.0, 1.0]); // tint
		setExprs(fxD, { 95: EXPR.focal, 110: EXPR.right, 118: EXPR.up, 126: EXPR.fwd });
		out.layers.push("SF_dome");

		// --- 本物の空: 画像 2 枚 (目玉オフ・いちばん下) + stardome_real (20入力: 14f + 3p3 + color + image 2・目玉オフ) ---
		out.step = "dome_real";
		var starLayer = target.layers.add(mapFootage("hipparcos_starmap_8k.png"));
		starLayer.name = "SF_starmap"; starLayer.enabled = false; starLayer.moveToEnd();
		var mwLayer = target.layers.add(mapFootage("milkyway_8k.png"));
		mwLayer.name = "SF_mwmap"; mwLayer.enabled = false; mwLayer.moveToEnd();
		var real = makeShapeLayer(target, "SF_dome_real"); // SF_dome のすぐ上 (中景・近景はこの後で上に積まれる)
		var fxR = applyStarField(real, shaderPath("stardome_real.glsl"));
		setVals(fxR, { 7: 1.0, 15: 12.0, 23: 0.7, 31: 1.0, 39: 1.0, 47: 1.0, 55: 1.0, 63: 1.0, 71: 0.6, 79: 0.05, 87: 5.6, 95: 0.0, 103: 0.0 });
		fxR.property(148).setValue([1.0, 1.0, 1.0, 1.0]); // tint
		setExprs(fxR, { 111: EXPR.focal, 126: EXPR.right, 134: EXPR.up, 142: EXPR.fwd });
		fxR.property(5).setValue(0); // Is Image Filter オフ = star_map・mw_map をレイヤーで指定できる
		real.enabled = false;
		out.layers.push("SF_dome_real");

		// --- 中景: starfield_v7 (19入力: 13f + 5p3 + color) 既定ルック(NOTES準拠) ---
		out.step = "mid";
		var mid = makeShapeLayer(target, "SF_mid");
		var fxM = applyStarField(mid, shaderPath("starfield_v7.glsl"));
		setVals(fxM, { 7: 0.7, 15: 1.0, 23: 0.5, 31: 0.85, 39: 2.5, 47: 1.5, 55: 48.0, 63: 14.0, 71: 1.0, 79: 0.65, 87: 2.0, 95: 1.5 });
		fxM.property(156).setValue([0.75, 0.85, 1.0, 1.0]); // tint
		setExprs(fxM, { 103: EXPR.focal, 118: EXPR.cam, 126: EXPR.vel, 134: EXPR.right, 142: EXPR.up, 150: EXPR.fwd });
		out.layers.push("SF_mid");

		// --- 近景: nearfield_v2 (19入力: 13f + 5p3 + color) ADD合成・尾なしの極小の粒・near_fade 10 ---
		out.step = "near";
		var near = makeShapeLayer(target, "SF_near");
		var fxN = applyStarField(near, shaderPath("nearfield_v2.glsl"));
		setVals(fxN, { 7: 0.8, 15: 0.006, 23: 0.0, 31: 2.6, 39: 0.15, 47: 20.0, 55: 0.35, 63: 0.0, 71: 10.0, 79: 2.0, 87: 6.0, 95: 1.0 });
		fxN.property(156).setValue([0.72, 0.78, 0.88, 1.0]); // tint
		setExprs(fxN, { 103: EXPR.focal, 118: EXPR.cam, 126: EXPR.vel, 134: EXPR.right, 142: EXPR.up, 150: EXPR.fwd });
		near.blendingMode = BlendingMode.ADD;
		out.layers.push("SF_near");

		// --- カメラ: 中央配置 + デフォルトのゆっくり前進 (expression。差し替え自由) ---
		out.step = "camera";
		var cam = target.layers.addCamera("SF_cam", [target.width / 2, target.height / 2]);
		cam.autoOrient = AutoOrientType.NO_AUTO_ORIENT;
		cam.property("ADBE Transform Group").property("ADBE Position").expression =
			"// StarField既定: ゆっくり前進 (消すかキーに置き換えて自由に演出)\n" +
			"[thisComp.width/2, thisComp.height/2, 240 * time]"; // Z増加=カメラ前進(星が手前に流れてくる)
		out.layers.push("SF_cam");

		// 画像の指定はレイヤーがそろってから (レイヤーの番号で渡す)
		fxR.property(157).setValue(starLayer.index); // star_map
		fxR.property(165).setValue(mwLayer.index);   // mw_map

		// レイヤー順 (上から): SF_cam / SF_near / SF_mid / SF_dome_real / SF_dome / SF_starmap / SF_mwmap
		// addShapeは常に最上段に積まれるので dome→mid→near の生成順で自動的にこの並びになる

		app.endUndoGroup();
		out.comp = target.name;
		out.step = "done";
	} catch (e) {
		try { app.endUndoGroup(); } catch (e2) {}
		out.error = e.name + ": " + e.message;
	}
	var txt = '{"comp":"' + out.comp + '","layers":"' + out.layers.join(",") + '","loads":"' + out.loads.join(" / ").replace(/"/g, "'") + '","step":"' + out.step + '","error":"' + (out.error || "").replace(/"/g, "'") + '"}';
	var rf = new File(Folder.temp.fsName + "/sf_setup_v2_result.json");
	rf.encoding = "UTF-8"; rf.open("w"); rf.write(txt); rf.close();
	if (out.error && !$.global.SF_SETUP_QUIET) {
		alert("StarField Setup failed (step: " + out.step + ")\n" + out.error +
			(/main entry point/i.test(out.error) ? "\n\nWindows Smart App Control may be blocking StarField.aex (unsigned dev build)." : ""));
	}
	txt;
})();

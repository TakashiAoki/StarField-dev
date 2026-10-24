StarField 開発版（Windows） v0.1.4 / 2026-10-24
Over Ray Studio 青木 隆

■ これは何
After Effects の中で、星空と、宇宙空間を進むときの星の流れを描くプラグインです。
GLSL シェーダーで描いていて、AE の 3D カメラに連動します。
カメラを前に進めると星が流れ、向きを変えると消失点が動きます。

3 枚のレイヤーを重ねて使います。
・SF_dome = 遠くの星空（天の川つき・星の位置は作り物）
・SF_mid = 中景の星の流れ
・SF_near = カメラの近くを流れる極小の浮遊物（尾を引かない粒）

遠くの星空は、作り物の SF_dome の代わりに「本物の空」SF_dome_real も使えます（v0.1.4 から）。
地球から見た実際の星（Hipparcos 星表の 11.8 万星・位置と明るさと色）と、実写の天の川（NASA の全天地図・暗黒帯まで実物どおり）です。
オリオン座や天の川の暗黒帯が、本物と同じ形・同じ向きで出ます。

開発中の版です。
Win AE 2025 で動作を確認しています（v0.1.3 は Win AE 2026 でも確認）。

■ 中身
・plugin\StarField.aex = プラグイン本体
・jsx\StarField_Setup_v2.jsx = 4 枚のレイヤーを自動で作るスクリプト
・stardome_v7.glsl・starfield_v7.glsl・nearfield_v2.glsl・stardome_real.glsl = シェーダー
・catalog\hipparcos_starmap_8k.png・catalog\milkyway_8k.png = 本物の空の全天の画像（8192×4096）
・samples\StarField_samples.aep = 見本のプロジェクト（設定違いのコンポ 4 つ・下の「見本」）
・LICENSE.txt・LICENSE_tweak_shader.txt・CREDITS.txt = ライセンスとクレジット

jsx フォルダ・catalog フォルダとシェーダーの並びは変えないでください。
スクリプトは、jsx の 1 つ上のフォルダからシェーダーと catalog を探します。

■ 入れ方
1. AE を終了する
2. plugin\StarField.aex を次のフォルダへコピーする（StarField フォルダは新しく作る・管理者の許可を求められます。v0.1.3 が入っていれば上書き）
C:\Program Files\Adobe\Adobe After Effects 2025\Support Files\Plug-ins\StarField\
3. AE を起動する

エフェクトのカテゴリ「Shaders」に「StarField」が出ていれば入っています。

■ 使い方
1. この StarField フォルダを、どこか（例: デスクトップ）に置いたままにする
2. AE で星を置きたいコンポを開く
3. ファイル → スクリプト → スクリプトファイルを実行 → jsx\StarField_Setup_v2.jsx を選ぶ
4. コンポに SF_cam・SF_near・SF_mid・SF_dome_real・SF_dome・SF_starmap・SF_mwmap ができる
   （SF_dome_real・SF_starmap・SF_mwmap は目玉オフ。下の「本物の空」）

コンポを開いていなければ、2048×1080・24fps・10 秒の「StarField」コンポを新しく作ってその中に置きます。

SF_cam の位置には「ゆっくり前に進む」式が入っています。
消すかキーに置き換えて、自由にカメラを動かしてください。

星の量・大きさ・明るさ・流れの長さ・色は、各レイヤーの StarField エフェクトで変えられます。
主な項目 : density（量）・star_size / size（大きさ）・brightness（明るさ）・streak（流れの長さ）・tint（色）

cam・vel・cam_right・cam_up・cam_fwd・focal には、カメラと連動させるための式が入っています。
ここは触らないでください。

■ 本物の空（SF_dome_real）
SF_dome_real の目玉を入れると、遠くの星空が本物の空になります（不透明なので SF_dome を覆います。重さが気になれば SF_dome の目玉を切ってください）。
SF_starmap・SF_mwmap は星の地図と天の川の画像です。目玉オフのまま、消さないでください（SF_dome_real がこの 2 枚を読みます）。
主な項目 :
・view_ra・view_dec = 空のどこをカメラの正面にするか（赤経［時］・赤緯［度］。北が上・東が左）
  例 : オリオン座 5.6 時・0°（Setup の既定）／いて座の銀河中心 17.6 時・−27°／はくちょう座 20.4 時・38°／北極星 2.5 時・89°
・view_roll = 空を画面の上で回す（＋で反時計回り）
・brightness = 全体の明るさ／mag_limit = 何等星まで描くか（6 で肉眼で見える星だけ・12 で星表のほぼ全部）
・contrast = 明るい星と暗い星の差（1 で実際の比・小さいほど暗い星が見える）／bloom = 明るい星ほど大きく描く強さ
・star_size・aa = 星の大きさと最小の太さ／saturation = 星と天の川の色の濃さ
・milkyway = 天の川の強さ／mw_contrast = 天の川の階調（小さいほど暗いところが持ち上がる）／mw_black = 天の川の画像の暗いところ（暗い星の積算のざらつき）を沈める量
「Is Image Filter」はオフのまま、star_map・mw_map は SF_starmap・SF_mwmap のままにしてください。
プレビューの解像度を「1/2」などにすると、星が暗く・少なく見えます（AE が画像を縮めて渡すため）。見え方は「フル画質」で確かめてください。

■ 見本（samples\StarField_samples.aep）
プラグインを入れた AE で開くと、設定違いのコンポが 4 つ入っています。
どれも 2048×872・24fps・6 秒（144F）・16bpc です。
各コンポの説明と主な調整項目は、下のとおりです。
シェーダーはプロジェクトの中に入っているので、シェーダーのファイルを選び直さなくても描けます。
近景（SF_near）は 4 つとも Setup の既定のままで、尾を引かない極小の粒（カメラ近くの星間浮遊物）です: streak 0・size 0.006・density 0.8・near_fade 10・near_soft 2・range 20・brightness 2.6。

・SF01_orbit = 通常露出の宇宙の回り込み
カメラが前進しながら向きを左右に振ります（SF_cam の Y 回転 +25°→−25°）。
中景は流れを短く細くしています（streak 0.05・star_size 0.35・brightness 2.4・aa 0.8）。star_size を下げると明るさも落ちるので、brightness で戻します。線の太さは aa（線の最小の太さ）で決まります。
遠景は向きだけで回り、中景・近景は近いほど速く流れます（視差）。進む向き＝消失点が画面を横切ります。

・SF02_cruise = 航行中のスターフィールド
カメラの向きは固定で、一定の速さで前進します（720px/s）。中景の星が消失点から流れる、いつもの見せ方です。
エフェクトの値は Setup の既定のままです。速さは SF_cam の位置のキーで変えられます（480px/s で落ち着いた航行・960px/s でワープ寄り）。

・SF03_milkyway = 増感して天の川を見せる
SF_dome の brightness（2.2）・dim_boost（3.0・暗い星を持ち上げる）・milkyway（1.0）・haze（3.0・雲）を上げて、天の川を見せています。
天の川は実写の全天マップを測った数字に合わせています。帯は細い芯と広い裾を持ち、帯に沿って明るい星の雲の塊があります。
暗黒帯は小さな暗い塊が集まった層で、帯の片側に寄って走ります。暗黒帯の中は暗い星も少なくなります。
帯の向きは mw_yaw・mw_pitch で変えられます（既定のカメラの向きだと、帯の中心は画面の外にあります）。帯の幅は mw_width です。
カメラは広角（28mm 相当）で、ゆっくり前に進みながら 3 軸で回ります（X 回転 0→−5°・Y 回転 +6→−6°・Z 回転 −5→−30°。どれもリニア）。
色は、SF_dome のすぐ上の調整レイヤー SF_grade で付けています（遠景だけに効きます・オフにすると色を付ける前の絵）。
背景は紺、帯の縁はすみれ色、芯は暖かい白（クリーム色）です。帯はほぼ縦に立てています（mw_pitch 10・mw_width 0.22）。
中身は AE に入っているエフェクトだけです : Exposure（+2.8）→ Glow（半径 120・弱く）→ Glow（しきい値 50%・半径 150・星のにじみ）→ CC Toner（明るさで 5 色に塗り分け）→ Curves（暗いところを下げ、明るいところを暖かい色に）→ Levels（個別のコントロール・ガンマ 0.8）
CC Toner の影の色は、Curves で暗いところの赤・緑が下がる分を先に足してあり、Curves の後の背景が紺になります。
Exposure を上げすぎると、明るい星の雲が白く飛んで玉のように膨らみます。
色は CC Toner の 5 色と Curves で、明るさは 1 つめの Exposure と最後の Levels で変えられます。

・SF04_realsky = 本物の空
遠景を本物の空（SF_dome_real）にしています。正面はいて座の銀河中心です（view_ra 17.6 時・view_dec −27°）。
星は実際の位置・明るさ・色、天の川は実写の全天地図なので、暗黒帯の形も本物どおりです。カメラは SF03 と同じ 28mm 相当で、ゆっくりパンします。
空のどこを正面にするかは view_ra・view_dec で、明るさは brightness・milkyway で変えられます（上の「本物の空」）。

自分のコンポで使うときは、見本のコンポからレイヤーをまとめてコピーして貼るか（SF_cam・SF_near・SF_mid・SF_dome_real・SF_dome・SF_starmap・SF_mwmap。SF03 は SF_grade も）、Setup のスクリプトで作り直してください。

■ 注意
・プロジェクトは 8bpc か 16bpc で使ってください（32bpc ではメモリが足りなくなって落ちることがあります）
・開発版なので、こまめに保存してください
・レンダリングする機械にも、同じようにプラグインを入れてください

プラグインには、まだ署名がありません。
Windows の「スマート アプリ コントロール」がオンの PC では読み込めず、「Couldn't find main entry point for StarField.aex」と出ます。
設定の場所 : Windows セキュリティ → アプリとブラウザー コントロール → スマート アプリ コントロールの設定

スクリプトが途中で止まったときは、理由が英語で表示されます。
その文面を Slack で送ってもらえると助かります。

/*
 * 管理端注册（F04）。**只注册、不导航** —— 理由见 `feature-patient/src/main/ets/PatientFeature.ets`：
 * 三个端的注册函数原先都用 `replace` 改当前路由，最后一次说了算，
 * 导致首屏永远是最后注册的那一端（实测为管理端），其余端的登录页不可达。
 */
export function registerAdminFeature(): void {
  // import 本身即完成注册（页面随模块打包）；不在这里改当前路由。
}

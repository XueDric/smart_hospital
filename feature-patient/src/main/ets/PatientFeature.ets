/*
 * 患者端注册（F04）。
 *
 * ★ 2026-10-17（评审实测缺陷）：这里原先是 `AppRouter.getInstance().replace(RouteName.LOGIN)`，
 *   医生端/管理端的注册函数也各调各的 `replace`，而 `EntryAbility.onCreate` 三个都调用，
 *   于是**最后一次 replace 决定首屏** —— 应用永远从「管理端登录页」启动，患者登录页在界面上
 *   没有任何入口，等于患者主流程被管理端挡住（模拟器全新安装实测确认）。
 *
 *   注册的语义是"把这个端的页面注册进来、让它可达"，**不是"导航到它"**：
 *   首屏由 `entry/src/main/ets/pages/Index.ets` 结合 `SessionStore` 决定，
 *   跨端入口是各登录页底部的显式链接。
 */
export function registerPatientFeature(): void {
  // 当前实现里 import 本身即完成注册（页面随模块打包）；**不要**在这里改当前路由。
}

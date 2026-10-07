// 负责人：彭翌菲
// 负责启动鉴权和邀请链接分流，并按权限加载主界面，
// 集中承载首页各 Tab 的切换与页面刷新信号。

import MemberListPage from './MemberListPage';
import MemberDetailPage from './MemberDetailPage';
import { ProfilePage } from './ProfilePage';
import MyTasksPage from './MyTasksPage';
import TaskListPage from './TaskListPage';
import PlanTreePage from './PlanTreePage';
import { AuthApi } from '../api/AuthApi';
import { Color, FontSize, Radius, Space } from '../core/Theme';
import { PermissionStore, UpdateData } from '../store/PermissionStore';
import { TokenStore } from '../store/TokenStore';
import { replaceTo } from '../utils/RouterUtils';
import { consumePendingInviteToken, openInviteRegistration } from '../utils/InviteDeepLink';

@Entry
@Component
struct Index {
  @State phase: string = 'loading';
  @State errorMsg: string = '';
  @State currentIndex: number = 0;
  @State showDetail: boolean = false;
  @State selectedMemberId: number = 0;
  @State refreshSignal: number = 0;

  private authApi: AuthApi = new AuthApi();
  private tokenStore: TokenStore = TokenStore.getInstance();
  private permissionStore: PermissionStore = PermissionStore.getInstance();
  private hasShown: boolean = false;

  aboutToAppear(): void {
    const inviteToken: string = consumePendingInviteToken();
    if (inviteToken.length > 0) {
      openInviteRegistration(inviteToken, true);
      return;
    }
    this.checkAuth();
  }

  onPageShow(): void {
    if (this.hasShown) {
      this.refreshSignal += 1;
      if (this.phase === 'home') {
        this.verifySession();
      }
    }
    this.hasShown = true;
  }

  build() {
    if (this.phase === 'loading') {
      this.loadingView()
    } else if (this.phase === 'error') {
      this.errorView()
    } else if (this.showDetail) {
      this.memberDetailView()
    } else {
      this.homeView()
    }
  }

  @Builder
  loadingView() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(Color.primary)
      Text('正在加载…')
        .fontSize(FontSize.body)
        .fontColor(Color.textTertiary)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Color.canvas)
  }

  @Builder
  errorView() {
    Column({ space: 16 }) {
      Text(this.errorMsg)
        .fontSize(FontSize.body)
        .fontColor(Color.textSecondary)
        .textAlign(TextAlign.Center)
      Button('重试')
        .width(120)
        .height(42)
        .fontColor(Color.onPrimary)
        .backgroundColor(Color.primary)
        .borderRadius(Radius.button)
        .onClick(() => this.checkAuth())
    }
    .width('100%')
    .height('100%')
    .padding(Space.page)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Color.canvas)
  }

  @Builder
  memberDetailView() {
    Column() {
      Row() {
        Image($r('app.media.chevron_left'))
          .width(24)
          .height(24)
          .onClick(() => {
            this.showDetail = false;
          })
        Text('成员详情')
          .fontSize(FontSize.title)
          .fontWeight(600)
          .fontColor(Color.textPrimary)
          .layoutWeight(1)
        Blank().width(28)
      }
      .width('100%')
      .height(52)
      .padding({ left: Space.page, right: Space.page })

      MemberDetailPage({
        memberId: this.selectedMemberId,
        onChanged: () => {
          // 改名 / 移出社团后让名录重新拉取（详情页自己是最新的）
          this.refreshSignal += 1;
        }
      })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.canvas)
  }

  @Builder
  homeView() {
    Tabs({ barPosition: BarPosition.End, index: this.currentIndex }) {
      TabContent() {
        MyTasksPage({ onOpenPlans: () => { this.currentIndex = 2 }, refreshSignal: this.refreshSignal })
      }
      .tabBar(this.tabBarBuilder('我的任务', 0, $r('app.media.tab_my_tasks'), $r('app.media.tab_my_tasks_active')))

      TabContent() {
        TaskListPage({ refreshSignal: this.refreshSignal })
      }
      .tabBar(this.tabBarBuilder('任务', 1, $r('app.media.tab_tasks'), $r('app.media.tab_tasks_active')))

      TabContent() {
        PlanTreePage({ refreshSignal: this.refreshSignal })
      }
      .tabBar(this.tabBarBuilder('课题', 2, $r('app.media.tab_plans'), $r('app.media.tab_plans_active')))

      TabContent() {
        MemberListPage({
          onMemberClick: (id: number) => {
            this.selectedMemberId = id;
            this.showDetail = true;
          },
          refreshSignal: this.refreshSignal
        })
      }
      .tabBar(this.tabBarBuilder('名录', 3, $r('app.media.tab_members'), $r('app.media.tab_members_active')))

      TabContent() {
        ProfilePage({ refreshSignal: this.refreshSignal })
      }
      .tabBar(this.tabBarBuilder('我的', 4, $r('app.media.tab_mine'), $r('app.media.tab_mine_active')))
    }
    .barMode(BarMode.Fixed)
    .barHeight(94)
    .barBackgroundColor(Color.surface)
    .onChange((index: number) => {
      this.currentIndex = index;
      this.refreshSignal += 1;
    })
    .width('100%')
    .height('100%')
  }

  @Builder
  tabBarBuilder(label: string, index: number, icon: Resource, activeIcon: Resource) {
    Column({ space: 2 }) {
      Column() {
        Image(this.currentIndex === index ? activeIcon : icon)
          .width(22)
          .height(22)
      }
      .width(40)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.currentIndex === index ? '#EFF6FF' : Color.surface)
      .borderRadius(12)

      Text(label)
        .fontSize(FontSize.navLabel)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.currentIndex === index ? '#2563EB' : '#9CA3AF')
    }
    .width('100%')
    .height(94)
    .padding({ top: 8, bottom: 20 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Color.surface)
    .border({ width: { top: 1 }, color: '#F3F4F6' })
  }

  private async checkAuth(): Promise<void> {
    this.phase = 'loading';
    this.errorMsg = '';
    const hasToken = await this.tokenStore.isLoggedIn();
    if (!hasToken) {
      replaceTo('pages/LoginPage');
      return;
    }
    const response = await this.authApi.me();
    if (!response.ok || response.data === undefined) {
      this.errorMsg = response.error?.message ?? '加载失败，请重试';
      this.phase = 'error';
      return;
    }
    const update: UpdateData = {
      user: response.data.member,
      permissions: response.data.permissions,
    };
    this.permissionStore.update(update);
    if (response.data.member.status === 'pending' || response.data.permissions.view_scope === 'none') {
      replaceTo('pages/PendingPage');
      return;
    }
    this.phase = 'home';
  }

  private async verifySession(): Promise<void> {
    const response = await this.authApi.me();
    if (response.ok && response.data !== undefined) {
      const update: UpdateData = {
        user: response.data.member,
        permissions: response.data.permissions,
      };
      this.permissionStore.update(update);
      if (response.data.member.status === 'pending' || response.data.permissions.view_scope === 'none') {
        replaceTo('pages/PendingPage');
      }
    }
  }
}

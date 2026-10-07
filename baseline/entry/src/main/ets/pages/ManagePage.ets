// 负责人：杨睿（前端组长）
// 管理页面 —— 部门管理 / 注册口令 / 招募链接 / 危险操作（会长移交 / 重置密码）
// 权限规则：
//   - 部门 CRUD / 会长移交按各自权限显示；重置密码候选统一由 PermissionStore.can() 判定
//   - 部门非空拦截：memberCount > 0 时禁止删除
// 工程化：Theme token 化、bindContentCover 化、注册口令"复制"对接 pasteboard
// 已接真接口：DeptApi / MemberApi（注册口令、招募链接、会长移交、重置密码），权限读 PermissionStore

import type { MemberBrief, MemberSelf, DeptBrief } from '../api/AuthApi';
import { MemberApi } from '../api/MemberApi';
import { DeptApi, DeptView, InviteLinkView, CreateLinkResponse } from '../api/DeptApi';
import { can, PermissionStore } from '../store/PermissionStore';
import { Color, StatusColor, Space, Radius, FontSize, Shadow } from '../core/Theme';
import { pasteboard } from '@kit.BasicServicesKit';

interface Dept {
  id: number;
  name: string;
  sort: number;
  memberCount: number;   // UI 衍生数据，来自 DeptView.member_count
}

interface InviteLink {
  id: string;            // 即后端 token
  deptName: string;
  url: string;
  enabled: boolean;
  createdAt: string;
}

interface MemberOption {
  id: number;
  name: string;
  deptName: string;
}

// ─── 类型映射（后端视图 → 页面本地 UI 类型）───

function deptViewToDept(d: DeptView): Dept {
  return { id: d.id, name: d.name, sort: d.sort, memberCount: d.member_count };
}

function linkViewToInviteLink(l: InviteLinkView): InviteLink {
  const created: string = l.created_at ?? '';
  const deptName: string = l.dept !== null ? l.dept.name : '';
  return {
    id: l.token,
    deptName: deptName,
    url: l.url,
    enabled: l.enabled,
    createdAt: created.length >= 10 ? created.slice(0, 10) : created,
  };
}

function createLinkResponseToInviteLink(resp: CreateLinkResponse): InviteLink {
  if (resp.link !== undefined) {
    return linkViewToInviteLink(resp.link);
  }
  return linkViewToInviteLink({
    token: resp.token,
    url: resp.url,
    dept: resp.dept ?? null,
    enabled: resp.enabled ?? true,
    created_at: resp.created_at ?? null,
  });
}

function memberToMemberOption(m: MemberBrief): MemberOption {
  return { id: m.id, name: m.name, deptName: m.dept !== null ? m.dept.name : '未分配' };
}

// 复制文本到剪贴板
function copyText(text: string): void {
  const pasteData: pasteboard.PasteData = pasteboard.createData(
    pasteboard.MIMETYPE_TEXT_PLAIN,
    text
  );
  pasteboard.getSystemPasteboard().setData(pasteData)
    .then((): void => {
      console.info('copied to clipboard');
    })
    .catch((e: Error): void => {
      console.error(`copy to clipboard failed: ${e.message}`);
    });
}

// 权限判断：读 PermissionStore 里 /auth/me 下发的 permissions 布尔（D-1，2026-09-16）。
// 仅用于画界面显隐，绝不能用它替代服务端校验。
function canManageDepts(): boolean {
  return PermissionStore.getInstance().permissions?.manage_depts ?? false;
}

function canViewRegisterCode(): boolean {
  return PermissionStore.getInstance().permissions?.view_register_code ?? false;
}

function canChangeRegisterCode(): boolean {
  return PermissionStore.getInstance().permissions?.change_register_code ?? false;
}

function canManageInviteLinks(): boolean {
  return PermissionStore.getInstance().permissions?.manage_invite_links ?? false;
}

function canTransferPresidency(): boolean {
  return PermissionStore.getInstance().permissions?.transfer_presidency ?? false;
}

@Component
struct SectionHeader {
  title: string = '';
  actionText: string = '';
  onAction: () => void = () => {};

  build() {
    Row() {
      Text(this.title)
        .fontSize(FontSize.subtitle)
        .fontWeight(FontWeight.Bold)
        .fontColor('#101828')

      Blank()

      if (this.actionText.length > 0) {
        Text(this.actionText)
          .fontSize(FontSize.body)
          .fontColor('#155DFC')
          .onClick(() => { this.onAction(); })
      }
    }
    .width('100%')
    .padding({ left: Space.page, right: Space.page, top: Space.xl, bottom: Space.sm })
  }
}

// ====== 部门管理 ======
@Component
struct DeptManageSection {
  @State depts: Dept[] = [];
  @State loading: boolean = true;
  // 弹窗状态
  @State showCreateDialog: boolean = false;
  @State showEditDialog: boolean = false;
  @State showDeleteConfirm: boolean = false;
  @State showDeleteBlocked: boolean = false;
  @State editingDeptId: number = 0;
  @State deletingDeptId: number = 0;
  @State deletingDeptName: string = '';
  @State deletingDeptCount: number = 0;
  // 输入值
  @State newDeptName: string = '';
  @State editDeptName: string = '';
  @State showSortDialog: boolean = false;
  @State sortingDeptId: number = 0;
  @State sortingDeptName: string = '';
  @State sortValue: string = '';
  private deptApi: DeptApi = new DeptApi();

  aboutToAppear(): void {
    this.loadDepts();
  }

  async loadDepts(): Promise<void> {
    this.loading = true;
    const resp = await this.deptApi.list();
    if (resp.ok && resp.data) {
      this.depts = resp.data.items.map((d: DeptView): Dept => deptViewToDept(d));
    }
    this.loading = false;
  }

  async submitCreate(): Promise<void> {
    if (this.newDeptName.length === 0) return;
    const resp = await this.deptApi.create({ name: this.newDeptName });
    if (resp.ok && resp.data) {
      this.depts = [...this.depts, deptViewToDept(resp.data)];
      this.newDeptName = '';
      this.showCreateDialog = false;
    } else {
      AlertDialog.show({
        title: '创建失败',
        message: resp.error?.message ?? '请重试',
        primaryButton: { value: '知道了', action: () => {} }
      });
    }
  }

  async submitEdit(): Promise<void> {
    if (this.editDeptName.length === 0) return;
    const resp = await this.deptApi.update(this.editingDeptId, { name: this.editDeptName });
    if (resp.ok && resp.data) {
      const updated: DeptView = resp.data;
      const next: Dept[] = [];
      for (let i = 0; i < this.depts.length; i++) {
        if (this.depts[i].id === updated.id) {
          next.push(deptViewToDept(updated));
        } else {
          next.push(this.depts[i]);
        }
      }
      this.depts = next;
      this.editDeptName = '';
      this.showEditDialog = false;
    } else {
      AlertDialog.show({
        title: '保存失败',
        message: resp.error?.message ?? '请重试',
        primaryButton: { value: '知道了', action: () => {} }
      });
    }
  }

  async submitDelete(): Promise<void> {
    const resp = await this.deptApi.delete_(this.deletingDeptId);
    if (resp.ok) {
      this.depts = this.depts.filter((d: Dept): boolean => d.id !== this.deletingDeptId);
      this.showDeleteConfirm = false;
    } else {
      this.showDeleteConfirm = false;
      AlertDialog.show({
        title: '删除失败',
        message: resp.error?.message ?? '请重试',
        primaryButton: { value: '知道了', action: () => {} }
      });
    }
  }


  private openSortDialog(dept: Dept): void {
    this.sortingDeptId = dept.id;
    this.sortingDeptName = dept.name;
    this.sortValue = dept.sort.toString();
    this.showSortDialog = true;
  }

  async submitSort(): Promise<void> {
    const value: number = Number(this.sortValue.trim());
    if (this.sortValue.trim().length === 0 || Number.isNaN(value)) {
      AlertDialog.show({
        title: '排序值无效',
        message: '请输入整数排序值。',
        primaryButton: { value: '知道了', action: () => {} }
      });
      return;
    }
    const resp = await this.deptApi.update(this.sortingDeptId, { sort: value });
    if (resp.ok && resp.data) {
      const updated: DeptView = resp.data;
      const next: Dept[] = [];
      for (let i = 0; i < this.depts.length; i++) {
        if (this.depts[i].id === updated.id) {
          next.push(deptViewToDept(updated));
        } else {
          next.push(this.depts[i]);
        }
      }
      next.sort((a: Dept, b: Dept): number => a.sort - b.sort);
      this.depts = next;
      this.showSortDialog = false;
    } else {
      AlertDialog.show({
        title: '排序失败',
        message: resp.error?.message ?? '请重试',
        primaryButton: { value: '知道了', action: () => {} }
      });
    }
  }

  @Builder
  createDialogBuilder() {
    Column() {
      Column() {
        Text('新建部门')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor('#101828')
          .margin({ bottom: Space.lg })

        TextInput({ text: this.newDeptName, placeholder: '输入部门名称' })
          .fontSize(FontSize.body)
          .fontColor('#101828')
          .backgroundColor('#F9FAFB')
          .borderRadius(Radius.input)
          .padding({ left: Space.md, right: Space.md })
          .height(40)
          .width('100%')
          .margin({ bottom: Space.lg })
          .onChange((v: string) => { this.newDeptName = v; })

        Row() {
          Button('取消')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.todo.bg)
            .fontColor('#6A7282')
            .layoutWeight(1)
            .borderRadius(12)
            .onClick(() => {
              this.newDeptName = '';
              this.showCreateDialog = false;
            })

          Button('创建')
            .type(ButtonType.Capsule)
            .backgroundColor('#155DFC')
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .margin({ left: Space.md })
            .borderRadius(12)
            .onClick(() => { this.submitCreate(); })
        }
        .width('100%')
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  editDialogBuilder() {
    Column() {
      Column() {
        Text('编辑部门名称')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor('#101828')
          .margin({ bottom: Space.lg })

        TextInput({ text: this.editDeptName, placeholder: '输入新名称' })
          .fontSize(FontSize.body)
          .fontColor('#101828')
          .backgroundColor('#F9FAFB')
          .borderRadius(Radius.input)
          .padding({ left: Space.md, right: Space.md })
          .height(40)
          .width('100%')
          .margin({ bottom: Space.lg })
          .onChange((v: string) => { this.editDeptName = v; })

        Row() {
          Button('取消')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.todo.bg)
            .fontColor('#6A7282')
            .layoutWeight(1)
            .borderRadius(12)
            .onClick(() => {
              this.editDeptName = '';
              this.showEditDialog = false;
            })

          Button('保存')
            .type(ButtonType.Capsule)
            .backgroundColor('#155DFC')
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .margin({ left: Space.md })
            .borderRadius(12)
            .onClick(() => { this.submitEdit(); })
        }
        .width('100%')
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }


  @Builder
  sortDialogBuilder() {
    Column() {
      Column() {
        Text('调整部门排序')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor('#101828')
          .margin({ bottom: Space.xs })

        Text(`部门：${this.sortingDeptName}`)
          .width('100%')
          .fontSize(FontSize.caption)
          .fontColor('#99A1AF')
          .margin({ bottom: Space.lg })

        TextInput({ text: this.sortValue, placeholder: '输入排序值' })
          .fontSize(FontSize.body)
          .fontColor('#101828')
          .backgroundColor('#F9FAFB')
          .borderRadius(Radius.input)
          .padding({ left: Space.md, right: Space.md })
          .height(40)
          .width('100%')
          .margin({ bottom: Space.lg })
          .onChange((v: string) => { this.sortValue = v; })

        Row() {
          Button('取消')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.todo.bg)
            .fontColor('#6A7282')
            .layoutWeight(1)
            .borderRadius(12)
            .onClick(() => {
              this.showSortDialog = false;
            })

          Button('保存排序')
            .type(ButtonType.Capsule)
            .backgroundColor('#155DFC')
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .margin({ left: Space.md })
            .borderRadius(12)
            .onClick(() => { this.submitSort(); })
        }
        .width('100%')
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  deleteBlockedBuilder() {
    Column() {
      Column() {
        Text('无法删除')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(StatusColor.overdue.fg)
          .margin({ bottom: Space.md })

        Text(`部门「${this.deletingDeptName}」下还有 ${this.deletingDeptCount} 名成员，需先转移或移出成员后才能删除。`)
          .fontSize(FontSize.body)
          .fontColor('#6A7282')
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ bottom: Space.lg })

        Button('知道了')
          .type(ButtonType.Capsule)
          .backgroundColor('#155DFC')
          .fontColor('#FFFFFF')
          .width('100%')
          .borderRadius(12)
          .onClick(() => {
            this.showDeleteBlocked = false;
          })
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  deleteConfirmBuilder() {
    Column() {
      Column() {
        Text('删除部门')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(StatusColor.overdue.fg)
          .margin({ bottom: Space.md })

        Text(`确认删除部门「${this.deletingDeptName}」？删除后不可恢复。`)
          .fontSize(FontSize.body)
          .fontColor('#6A7282')
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ bottom: Space.lg })

        Row() {
          Button('取消')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.todo.bg)
            .fontColor('#6A7282')
            .layoutWeight(1)
            .borderRadius(12)
            .onClick(() => {
              this.showDeleteConfirm = false;
            })

          Button('删除')
            .type(ButtonType.Capsule)
            .backgroundColor(StatusColor.overdue.bg)
            .fontColor(StatusColor.overdue.fg)
            .layoutWeight(1)
            .margin({ left: Space.md })
            .borderRadius(12)
            .onClick(() => { this.submitDelete(); })
        }
        .width('100%')
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  deptDialogBuilder() {
    if (this.showCreateDialog) {
      this.createDialogBuilder()
    } else if (this.showEditDialog) {
      this.editDialogBuilder()
    } else if (this.showSortDialog) {
      this.sortDialogBuilder()
    } else if (this.showDeleteBlocked) {
      this.deleteBlockedBuilder()
    } else if (this.showDeleteConfirm) {
      this.deleteConfirmBuilder()
    }
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text('部门与组织')
            .fontSize(FontSize.body)
            .fontWeight(FontWeight.Bold)
            .fontColor('#101828')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (canManageDepts()) {
          Text('+ 新建')
            .fontSize(FontSize.caption)
            .fontColor('#155DFC')
            .onClick(() => {
              this.newDeptName = '';
              this.showCreateDialog = true;
            })
        }
      }
      .width('100%')

      if (this.loading) {
        Row() {
          LoadingProgress().width(24).height(24).color('#155DFC')
        }
        .width('100%')
        .height(64)
        .justifyContent(FlexAlign.Center)
      } else if (this.depts.length === 0) {
        Text('暂无部门')
          .width('100%')
          .fontSize(FontSize.caption)
          .fontColor('#99A1AF')
          .textAlign(TextAlign.Center)
          .padding({ top: 24, bottom: 16 })
      } else {
        ForEach(this.depts, (dept: Dept, index: number) => {
          Column() {
            Row() {
              Text(dept.name)
                .layoutWeight(1)
                .fontSize(FontSize.body)
                .fontColor('#101828')

              if (canManageDepts()) {
                Row({ space: 12 }) {
                  Text('改名')
                    .fontSize(FontSize.caption)
                    .fontColor('#155DFC')
                    .onClick(() => {
                      this.editingDeptId = dept.id;
                      this.editDeptName = dept.name;
                      this.showEditDialog = true;
                    })

                  Text('排序')
                    .fontSize(FontSize.caption)
                    .fontColor('#155DFC')
                    .onClick(() => { this.openSortDialog(dept); })

                  Text('删除')
                    .fontSize(FontSize.caption)
                    .fontColor('#155DFC')
                    .onClick(() => {
                      if (dept.memberCount > 0) {
                        this.deletingDeptId = dept.id;
                        this.deletingDeptName = dept.name;
                        this.deletingDeptCount = dept.memberCount;
                        this.showDeleteBlocked = true;
                      } else {
                        this.deletingDeptId = dept.id;
                        this.deletingDeptName = dept.name;
                        this.deletingDeptCount = 0;
                        this.showDeleteConfirm = true;
                      }
                    })
                }
              }
            }
            .width('100%')
            .height(40)

            if (index < this.depts.length - 1) {
              Divider()
                .strokeWidth(1)
                .color('#F3F4F6')
            }
          }
          .width('100%')
        }, (dept: Dept) => dept.id.toString())
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F3F4F6' })
    .borderRadius(12)
    .shadow(Shadow.L1)
    .bindContentCover(
      this.showCreateDialog || this.showEditDialog || this.showSortDialog ||
        this.showDeleteBlocked || this.showDeleteConfirm,
      this.deptDialogBuilder
    )
  }
}

// ====== 注册口令 ======
@Component
struct RegisterConfigSection {
  @State code: string = '';
  @State loading: boolean = true;
  @State showRotateConfirm: boolean = false;
  @State showChangeDialog: boolean = false;
  @State newCode: string = '';
  private memberApi: MemberApi = new MemberApi();

  aboutToAppear(): void {
    this.loadCode();
  }

  async loadCode(): Promise<void> {
    this.loading = true;
    const resp = await this.memberApi.getRegisterCode();
    if (resp.ok && resp.data) {
      this.code = resp.data.code;
    }
    this.loading = false;
  }

  async submitChange(): Promise<void> {
    if (this.newCode.length === 0) return;
    const resp = await this.memberApi.setRegisterCode({ code: this.newCode });
    if (resp.ok && resp.data) {
      this.code = resp.data.code;
      this.newCode = '';
      this.showChangeDialog = false;
    } else {
      AlertDialog.show({
        title: '更换失败',
        message: resp.error?.message ?? '请重试',
        primaryButton: { value: '知道了', action: () => {} }
      });
    }
  }

  async submitRotate(): Promise<void> {
    const resp = await this.memberApi.rotateRegisterCode();
    if (resp.ok && resp.data) {
      this.code = resp.data.code;
      this.showRotateConfirm = false;
    } else {
      this.showRotateConfirm = false;
      AlertDialog.show({
        title: '轮换失败',
        message: resp.error?.message ?? '请重试',
        primaryButton: { value: '知道了', action: () => {} }
      });
    }
  }

  @Builder
  changeDialogBuilder() {
    Column() {
      Column() {
        Text('更换注册口令')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor('#101828')
          .margin({ bottom: Space.lg })

        TextInput({ text: this.newCode, placeholder: '输入新口令' })
          .fontSize(FontSize.body)
          .fontColor('#101828')
          .backgroundColor('#F9FAFB')
          .borderRadius(Radius.input)
          .padding({ left: Space.md, right: Space.md })
          .height(40)
          .width('100%')
          .margin({ bottom: Space.lg })
          .onChange((v: string) => { this.newCode = v; })

        Row() {
          Button('取消')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.todo.bg)
            .fontColor('#6A7282')
            .layoutWeight(1)
            .borderRadius(12)
            .onClick(() => {
              this.newCode = '';
              this.showChangeDialog = false;
            })

          Button('保存')
            .type(ButtonType.Capsule)
            .backgroundColor('#155DFC')
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .margin({ left: Space.md })
            .borderRadius(12)
            .onClick(() => { this.submitChange(); })
        }
        .width('100%')
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  registerDialogBuilder() {
    if (this.showChangeDialog) {
      this.changeDialogBuilder()
    } else {
      this.rotateDialogBuilder()
    }
  }

  @Builder
  rotateDialogBuilder() {
    Column() {
      Column() {
        Text('随机轮换口令')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor('#101828')
          .margin({ bottom: Space.md })

        Text('将生成新的随机口令，旧口令立即失效。确认？')
          .fontSize(FontSize.body)
          .fontColor('#6A7282')
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ bottom: Space.lg })

        Row() {
          Button('取消')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.todo.bg)
            .fontColor('#6A7282')
            .layoutWeight(1)
            .borderRadius(12)
            .onClick(() => {
              this.showRotateConfirm = false;
            })

          Button('确认轮换')
            .type(ButtonType.Capsule)
            .backgroundColor('#155DFC')
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .margin({ left: Space.md })
            .borderRadius(12)
            .onClick(() => { this.submitRotate(); })
        }
        .width('100%')
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      Text('注册口令')
        .width('100%')
        .fontSize(FontSize.body)
        .fontWeight(FontWeight.Bold)
        .fontColor('#101828')

      Row({ space: 8 }) {
        Text(this.loading ? '加载中…' : this.code)
          .layoutWeight(1)
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontFamily('Inter')
          .fontFeature('"tnum" 1')
          .fontColor('#101828')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick(() => {
            if (!this.loading && this.code.length > 0) {
              copyText(this.code);
            }
          })

        if (canChangeRegisterCode()) {
          Button('更换')
            .type(ButtonType.Normal)
            .height(34)
            .fontSize(FontSize.caption)
            .fontColor('#6A7282')
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#F3F4F6' })
            .borderRadius(Radius.input)
            .padding({ left: 12, right: 12 })
            .enabled(!this.loading)
            .onClick(() => {
              this.newCode = '';
              this.showChangeDialog = true;
            })

          Button('随机轮换')
            .type(ButtonType.Normal)
            .height(34)
            .fontSize(FontSize.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FFFFFF')
            .backgroundColor('#155DFC')
            .borderRadius(Radius.input)
            .padding({ left: 12, right: 12 })
            .enabled(!this.loading)
            .onClick(() => {
              this.showRotateConfirm = true;
            })
        }
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F3F4F6' })
    .borderRadius(12)
    .shadow(Shadow.L1)
    .bindContentCover(this.showChangeDialog || this.showRotateConfirm, this.registerDialogBuilder)
  }
}

// ====== 招募链接 ======
@Component
struct CreateLinkDialog {
  depts: Dept[] = [];
  onConfirm: (deptIndex: number) => void = (_d: number) => {};
  onCancel: () => void = () => {};
  @State selectedDeptIndex: number = 0;

  build() {
    Column() {
      Column() {
        Text('生成招募链接')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor('#101828')
          .margin({ bottom: Space.lg })

        Text('选择部门')
          .fontSize(FontSize.body)
          .fontColor('#6A7282')
          .width('100%')
          .margin({ bottom: Space.xs })

        Select(this.depts.map((d: Dept): SelectOption => ({ value: d.name })))
          .selected(this.selectedDeptIndex)
          .value(this.depts.length > 0 ? this.depts[this.selectedDeptIndex].name : '')
          .onSelect((index: number) => { this.selectedDeptIndex = index; })
          .width('100%')
          .margin({ bottom: Space.xl })

        Row() {
          Button('取消')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.todo.bg)
            .fontColor('#6A7282')
            .layoutWeight(1)
            .borderRadius(12)
            .onClick(() => { this.onCancel(); })

          Button('生成')
            .type(ButtonType.Normal)
            .backgroundColor('#155DFC')
            .fontColor('#FFFFFF')
            .layoutWeight(1)
            .borderRadius(12)
            .margin({ left: Space.md })
            .onClick(() => { this.onConfirm(this.selectedDeptIndex); })
        }
        .width('100%')
      }
      .width('80%')
      .padding(Space.xl)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}

@Component
struct InviteLinkSection {
  @State links: InviteLink[] = [];
  @State depts: Dept[] = [];
  @State loading: boolean = true;
  @State creating: boolean = false;
  @State showCreateDialog: boolean = false;
  private deptApi: DeptApi = new DeptApi();

  aboutToAppear(): void {
    this.loadLinks();
    this.loadDepts();
  }

  async loadLinks(): Promise<void> {
    this.loading = true;
    const resp = await this.deptApi.listLinks();
    if (resp.ok && resp.data) {
      const visible: InviteLink[] = [];
      for (let i = 0; i < resp.data.items.length; i++) {
        const item: InviteLink = linkViewToInviteLink(resp.data.items[i]);
        if (item.enabled) {
          visible.push(item);
        }
      }
      this.links = visible;
    }
    this.loading = false;
  }

  async loadDepts(): Promise<void> {
    const resp = await this.deptApi.list();
    if (resp.ok && resp.data) {
      this.depts = resp.data.items.map((d: DeptView): Dept => deptViewToDept(d));
    }
  }

  // 停用链接（后端 DELETE 语义：enabled 置 false，不做重新启用）
  async disableLink(id: string): Promise<void> {
    const resp = await this.deptApi.toggleLink(id);
    if (resp.ok && resp.data) {
      const next: InviteLink[] = [];
      for (let i = 0; i < this.links.length; i++) {
        if (this.links[i].id !== id) {
          next.push(this.links[i]);
        }
      }
      this.links = next;
    } else {
      AlertDialog.show({
        title: '操作失败',
        message: resp.error?.message ?? '请重试',
        primaryButton: { value: '知道了', action: () => {} }
      });
    }
  }

  async createLink(deptIndex: number): Promise<void> {
    const dept: Dept = this.depts[deptIndex];
    if (dept === undefined) {
      return;
    }
    if (this.creating) {
      return;
    }
    this.creating = true;
    const resp = await this.deptApi.createLink(dept.id);
    this.creating = false;
    if (resp.ok && resp.data) {
      const created: InviteLink = createLinkResponseToInviteLink(resp.data);
      const next: InviteLink[] = [created];
      for (let i = 0; i < this.links.length; i++) {
        if (this.links[i].id !== created.id) {
          next.push(this.links[i]);
        }
      }
      this.links = next;
      this.showCreateDialog = false;
    } else {
      AlertDialog.show({
        title: '生成失败',
        message: resp.error?.message ?? '请重试',
        primaryButton: { value: '知道了', action: () => {} }
      });
    }
  }

  @Builder
  createDialogBuilder() {
    CreateLinkDialog({
      depts: this.depts,
      onConfirm: (deptIndex: number): void => {
        this.createLink(deptIndex);
      },
      onCancel: (): void => {
        this.showCreateDialog = false;
      }
    })
  }

  build() {
    Column() {
      Row() {
        Text('招募链接')
          .layoutWeight(1)
          .fontSize(FontSize.body)
          .fontWeight(FontWeight.Bold)
          .fontColor('#101828')

        if (canManageInviteLinks()) {
          Text('+ 生成链接')
            .fontSize(FontSize.caption)
            .fontColor('#155DFC')
            .enabled(this.depts.length > 0)
            .onClick(() => {
              this.showCreateDialog = true;
            })
        }
      }
      .width('100%')

      if (this.loading) {
        Row() {
          LoadingProgress().width(24).height(24).color('#155DFC')
        }
        .width('100%')
        .height(64)
        .justifyContent(FlexAlign.Center)
      } else if (this.links.length === 0) {
        Text('暂无招募链接')
          .width('100%')
          .fontSize(FontSize.caption)
          .fontColor('#99A1AF')
          .textAlign(TextAlign.Center)
          .padding({ top: 24, bottom: 16 })
      } else {
        ForEach(this.links, (link: InviteLink, index: number) => {
          Column() {
            Column({ space: 8 }) {
              Text(link.url.length > 0 ? link.url : `join/${link.id}`)
                .width('100%')
                .fontSize(12)
                .fontFamily('Inter')
                .fontColor('#6A7282')

              Row({ space: 8 }) {
                Text(link.enabled ? '启用中' : '已停用')
                  .fontSize(FontSize.caption)
                  .fontColor(link.enabled ? '#155DFC' : '#99A1AF')
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .backgroundColor(link.enabled ? '#EFF6FF' : StatusColor.todo.bg)
                  .border({ width: 1, color: link.enabled ? '#BEDBFF' : '#F3F4F6' })
                  .borderRadius(Radius.input)

                Text('复制')
                  .fontSize(FontSize.caption)
                  .fontColor('#155DFC')
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .backgroundColor('#EFF6FF')
                  .border({ width: 1, color: '#BEDBFF' })
                  .borderRadius(Radius.input)
                  .onClick(() => {
                    copyText(link.url.length > 0 ? link.url : `join/${link.id}`);
                  })

                if (canManageInviteLinks() && link.enabled) {
                  Text('停用')
                    .fontSize(FontSize.caption)
                    .fontColor('#6A7282')
                    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .border({ width: 1, color: '#F3F4F6' })
                    .borderRadius(Radius.input)
                    .onClick(() => { this.disableLink(link.id); })
                }
              }
              .width('100%')
              .justifyContent(FlexAlign.End)
            }
            .width('100%')

            if (index < this.links.length - 1) {
              Divider()
                .strokeWidth(1)
                .color('#F3F4F6')
                .margin({ top: 12, bottom: 12 })
            }
          }
          .width('100%')
          .padding({ top: index === 0 ? 14 : 0 })
        }, (link: InviteLink) => `${link.id}-${link.enabled ? '1' : '0'}`)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 14 })
    .backgroundColor('#FFFFFF')
    .border({ width: 1, color: '#F3F4F6' })
    .borderRadius(12)
    .shadow(Shadow.L1)
    .bindContentCover(this.showCreateDialog, this.createDialogBuilder)
  }
}

// ====== 危险操作区（按权限显隐）======
@Component
struct DangerZoneSection {
  @State members: MemberBrief[] = [];
  @State showTransferDialog: boolean = false;
  @State showResetDialog: boolean = false;
  @State showTransferResult: boolean = false;
  @State transferResultMsg: string = '';
  @State resetResultMsg: string = '';
  @State resetResultPassword: string = '';
  @State selectedTransferIndex: number = 0;
  @State selectedResetIndex: number = 0;
  @State transferring: boolean = false;
  @State resetting: boolean = false;
  private memberApi: MemberApi = new MemberApi();

  aboutToAppear(): void {
    this.loadMembers();
  }

  async loadMembers(): Promise<void> {
    // 分页拉全量成员：服务端单页上限 200（默认 50），会长移交/重置密码候选不能只取第一页
    const size: number = 200;
    const all: MemberBrief[] = [];
    let page: number = 1;
    let total: number = 0;
    let keepGoing: boolean = true;
    while (keepGoing) {
      const resp = await this.memberApi.list({ page: page, size: size });
      if (resp.ok && resp.data) {
        total = resp.data.total;
        const items: MemberBrief[] = resp.data.items;
        for (let i = 0; i < items.length; i++) {
          all.push(items[i]);
        }
        if (items.length === 0 || all.length >= total) {
          keepGoing = false;
        } else {
          page += 1;
        }
      } else {
        keepGoing = false; // 出错到此为止，用已拿到的部分
      }
    }
    this.members = all.filter((m: MemberBrief): boolean => m.status === 'active');
  }

  private currentUser(): MemberSelf | null {
    return PermissionStore.getInstance().userInfo;
  }

  private canResetMember(m: MemberBrief): boolean {
    const user: MemberSelf | null = this.currentUser();
    if (user === null) {
      return false;
    }
    return can(user, 'ResetPassword', m);
  }

  private canResetMembers(): boolean {
    return this.resetCandidates().length > 0;
  }

  private transferCandidateLabel(): string {
    const candidates: MemberOption[] = this.transferCandidates();
    if (candidates.length === 0) {
      return '暂无可移交成员';
    }
    return candidates[0].name;
  }

  // 移交给的候选（排除自己）
  transferCandidates(): MemberOption[] {
    const current: MemberSelf | null = this.currentUser();
    const selfId: number = current !== null ? current.id : -1;
    const list: MemberOption[] = [];
    for (let i = 0; i < this.members.length; i++) {
      const m: MemberBrief = this.members[i];
      if (m.id !== selfId) {
        list.push(memberToMemberOption(m));
      }
    }
    return list;
  }

  // 重置密码候选：只保留 can(user, 'ResetPassword', target) 放行的人
  resetCandidates(): MemberOption[] {
    const list: MemberOption[] = [];
    for (let i = 0; i < this.members.length; i++) {
      const m: MemberBrief = this.members[i];
      if (this.canResetMember(m)) {
        list.push(memberToMemberOption(m));
      }
    }
    return list;
  }

  async submitTransfer(): Promise<void> {
    if (this.transferring) return;
    const candidates: MemberOption[] = this.transferCandidates();
    const target: MemberOption = candidates[this.selectedTransferIndex];
    if (target === undefined) return;
    // 二次确认：会长移交不可撤销，需再次确认
    AlertDialog.show({
      title: '二次确认',
      message: `确定将会长权限移交给 ${target.name}（${target.deptName}）吗？此操作不可撤销，你将成为普通成员。`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '确定移交', action: () => { this.doTransfer(target); } }
    });
  }

  async doTransfer(target: MemberOption): Promise<void> {
    if (this.transferring) return;
    this.transferring = true;
    try {
      const resp = await this.memberApi.transferPresidency(target.id);
      if (resp.ok && resp.data) {
        this.transferResultMsg = `已将会长权限移交至 ${target.name}（${target.deptName}）`;
        this.showTransferDialog = false;
        this.showTransferResult = true;
      } else {
        AlertDialog.show({
          title: '移交失败',
          message: resp.error?.message ?? '请重试',
          primaryButton: { value: '知道了', action: () => {} }
        });
      }
    } finally {
      this.transferring = false;
    }
  }

  async submitReset(): Promise<void> {
    if (this.resetting) return;
    const candidates: MemberOption[] = this.resetCandidates();
    const target: MemberOption = candidates[this.selectedResetIndex];
    if (target === undefined) return;
    this.resetting = true;
    try {
      const resp = await this.memberApi.resetPassword(target.id);
      if (resp.ok && resp.data) {
        this.resetResultMsg = `已为 ${target.name} 重置密码`;
        this.resetResultPassword = resp.data.temporary_password;
        this.showResetDialog = false;
        setTimeout(() => { this.showResetDialog = true; }, 50);
      } else {
        AlertDialog.show({
          title: '重置失败',
          message: resp.error?.message ?? '请重试',
          primaryButton: { value: '知道了', action: () => {} }
        });
      }
    } finally {
      this.resetting = false;
    }
  }

  @Builder
  transferOverlayBuilder() {
    if (this.showTransferDialog) {
      this.transferDialogBuilder()
    } else {
      this.transferResultBuilder()
    }
  }

  @Builder
  transferDialogBuilder() {
    Column() {
      Column() {
        Text('移交会长')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(StatusColor.overdue.fg)
          .margin({ bottom: Space.sm })

        Text('将会长权限转让给以下成员，此操作不可撤销。')
          .fontSize(FontSize.caption)
          .fontColor('#6A7282')
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ bottom: Space.lg })

        Text('选择新会长')
          .fontSize(FontSize.body)
          .fontColor('#6A7282')
          .width('100%')
          .margin({ bottom: Space.xs })

        Select(this.transferCandidates().map((m: MemberOption): SelectOption => ({ value: `${m.name}（${m.deptName}）` })))
          .selected(this.selectedTransferIndex)
          .value(this.transferCandidates().length > 0 ? this.transferCandidates()[this.selectedTransferIndex].name : '请选择')
          .onSelect((index: number) => { this.selectedTransferIndex = index; })
          .width('100%')
          .margin({ bottom: Space.xl })

        Row() {
          Button('取消')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.todo.bg)
            .fontColor('#6A7282')
            .layoutWeight(1)
            .borderRadius(12)
            .onClick(() => {
              this.showTransferDialog = false;
            })

          Button(this.transferring ? '移交中…' : '确认移交')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.overdue.bg)
            .fontColor(StatusColor.overdue.fg)
            .layoutWeight(1)
            .borderRadius(12)
            .margin({ left: Space.md })
            .enabled(!this.transferring)
            .onClick(() => { this.submitTransfer(); })
        }
        .width('100%')
      }
      .width('80%')
      .padding(Space.xl)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  transferResultBuilder() {
    Column() {
      Column() {
        Text('移交成功')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(StatusColor.done.fg)
          .margin({ bottom: Space.md })

        Text(this.transferResultMsg)
          .fontSize(FontSize.body)
          .fontColor('#6A7282')
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ bottom: Space.lg })

        Button('知道了')
          .type(ButtonType.Capsule)
          .backgroundColor(StatusColor.done.bg)
          .fontColor(StatusColor.done.fg)
          .width('100%')
          .borderRadius(12)
          .onClick(() => {
            this.transferResultMsg = '';
            this.showTransferResult = false;
          })
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  resetOverlayBuilder() {
    if (this.resetResultPassword.length > 0) {
      this.resetResultBuilder()
    } else {
      this.resetDialogBuilder()
    }
  }

  @Builder
  resetDialogBuilder() {
    Column() {
      Column() {
        Text('重置成员密码')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(StatusColor.blocked.fg)
          .margin({ bottom: Space.sm })

        Text('为成员生成一次性临时密码，原密码立即失效。')
          .fontSize(FontSize.caption)
          .fontColor('#6A7282')
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ bottom: Space.lg })

        Text('选择成员')
          .fontSize(FontSize.body)
          .fontColor('#6A7282')
          .width('100%')
          .margin({ bottom: Space.xs })

        Select(this.resetCandidates().map((m: MemberOption): SelectOption => ({ value: `${m.name}（${m.deptName}）` })))
          .selected(this.selectedResetIndex)
          .value(this.resetCandidates().length > 0 ? this.resetCandidates()[this.selectedResetIndex].name : '请选择')
          .onSelect((index: number) => { this.selectedResetIndex = index; })
          .width('100%')
          .margin({ bottom: Space.xl })

        Row() {
          Button('取消')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.todo.bg)
            .fontColor('#6A7282')
            .layoutWeight(1)
            .borderRadius(12)
            .onClick(() => {
              this.resetResultMsg = '';
              this.resetResultPassword = '';
              this.showResetDialog = false;
            })

          Button(this.resetting ? '签发中…' : '生成临时密码')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.blocked.bg)
            .fontColor(StatusColor.blocked.fg)
            .layoutWeight(1)
            .borderRadius(12)
            .margin({ left: Space.md })
            .enabled(!this.resetting && this.resetCandidates().length > 0)
            .onClick(() => { this.submitReset(); })
        }
        .width('100%')
      }
      .width('80%')
      .padding(Space.xl)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  resetResultBuilder() {
    Column() {
      Column() {
        Text('重置成功')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(StatusColor.done.fg)
          .margin({ bottom: Space.sm })

        Text(this.resetResultMsg)
          .fontSize(FontSize.caption)
          .fontColor('#6A7282')
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ bottom: Space.md })

        Text('一次性临时密码')
          .fontSize(FontSize.caption)
          .fontColor('#99A1AF')
          .margin({ bottom: Space.xs })

        Text(this.resetResultPassword)
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#155DFC')
          .margin({ bottom: Space.lg })

        Row() {
          Button('复制密码')
            .type(ButtonType.Capsule)
            .backgroundColor('#EFF6FF')
            .fontColor('#155DFC')
            .layoutWeight(1)
            .onClick(() => { copyText(this.resetResultPassword); })

          Button('知道了')
            .type(ButtonType.Capsule)
            .backgroundColor(StatusColor.done.bg)
            .fontColor(StatusColor.done.fg)
            .layoutWeight(1)
            .margin({ left: Space.md })
            .onClick(() => {
              this.resetResultMsg = '';
              this.resetResultPassword = '';
              this.showResetDialog = false;
            })
        }
        .width('100%')
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor('#FFFFFF')
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column({ space: 12 }) {
      if (canTransferPresidency()) {
        Column() {
          Text('会长移交')
            .width('100%')
            .fontSize(FontSize.body)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FB2C36')

          Text('原子操作：目标变成会长，自己降为你选的档位，两步同时生效。社团必须始终保留至少一位会长，因此这一项需要二次确认。')
            .width('100%')
            .fontSize(12)
            .fontColor('#6A7282')
            .lineHeight(17)
            .margin({ top: 4, bottom: 12 })

          Button(`移交给 ${this.transferCandidateLabel()}`)
            .width('100%')
            .height(40)
            .type(ButtonType.Normal)
            .fontSize(FontSize.body)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FB2C36')
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#FFC9C9' })
            .borderRadius(12)
            .onClick(() => {
              this.showTransferDialog = true;
            })
        }
        .width('100%')
        .padding(16)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#FFC9C9' })
        .borderRadius(12)
        .shadow(Shadow.L1)
        .bindContentCover(this.showTransferDialog || this.showTransferResult, this.transferOverlayBuilder)
      }

      if (this.canResetMembers()) {
        Column() {
          Text('重置成员密码')
            .width('100%')
            .fontSize(FontSize.body)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FB2C36')

          Text('为成员生成一次性临时密码，原密码立即失效。仅能对权限低于自己的成员操作。')
            .width('100%')
            .fontSize(12)
            .fontColor('#6A7282')
            .lineHeight(17)
            .margin({ top: 4, bottom: 12 })

          Button('选择成员并生成临时密码')
            .width('100%')
            .height(40)
            .type(ButtonType.Normal)
            .fontSize(FontSize.body)
            .fontWeight(FontWeight.Medium)
            .fontColor('#FB2C36')
            .backgroundColor('#FFFFFF')
            .border({ width: 1, color: '#FFC9C9' })
            .borderRadius(12)
            .onClick(() => {
              this.resetResultMsg = '';
              this.resetResultPassword = '';
              this.showResetDialog = true;
            })
        }
        .width('100%')
        .padding(16)
        .backgroundColor('#FFFFFF')
        .border({ width: 1, color: '#FFC9C9' })
        .borderRadius(12)
        .shadow(Shadow.L1)
        .bindContentCover(this.showResetDialog, this.resetOverlayBuilder)
      }
    }
    .width('100%')
  }
}


@Component
export default struct ManagePage {
  build() {
    Scroll() {
      Column({ space: 12 }) {
        if (canManageDepts()) {
          DeptManageSection()
        }
        if (canViewRegisterCode()) {
          RegisterConfigSection()
        }
        if (canManageInviteLinks()) {
          InviteLinkSection()
        }
        DangerZoneSection()

        Text('口令与链接都是敏感信息：轮换后旧口令立即失效；客户端不得落盘长存，也不得打印到设备日志。')
          .width('100%')
          .fontSize(12)
          .fontColor('#99A1AF')
          .lineHeight(17)
      }
      .width('100%')
      .padding({ left: Space.page, right: Space.page, top: 12, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F9FAFB')
    .scrollBar(BarState.Off)
  }
}

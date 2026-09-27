import { AbilityConstant, UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
export default class EntryAbility extends UIAbility {
  onCreate(want:Want,launchParam:AbilityConstant.LaunchParam):void{AppStorage.setOrCreate('beanSystemDark',this.context.config.colorMode===ConfigurationConstant.ColorMode.COLOR_MODE_DARK);}
  onConfigurationUpdate(config:Configuration):void{AppStorage.setOrCreate('beanSystemDark',config.colorMode===ConfigurationConstant.ColorMode.COLOR_MODE_DARK);}
  onWindowStageCreate(stage:window.WindowStage):void{stage.loadContent('pages/Index');}
}

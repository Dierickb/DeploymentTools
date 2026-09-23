#Requires -Version 5.1
<#
.SYNOPSIS
    Interfaz grafica (WPF) del Deployment Toolkit.

.DESCRIPTION
    Misma funcionalidad que Deploy-Menu.ps1, pero en ventana en vez de
    consola. NO duplica nada de la logica: cada tarea de la izquierda arma
    un splat de parametros y llama a la MISMA funcion publica del modulo
    (Invoke-DeployApp, Invoke-KbDeployment, etc.) que usan el menu de
    consola y los scripts\run_*.ps1.

    Lo importante del planteo esta en como NO se traba la ventana:

      - El despliegue corre en un runspace aparte del hilo de interfaz. Si
        se llamara a Invoke-* directo desde el handler del boton, la
        ventana quedaria congelada ("No responde") todo el despliegue,
        porque esas funciones son bloqueantes hasta que termina el ultimo
        equipo.
      - Ese runspace le pasa a Invoke-ThrottledDeployment una cola
        thread-safe (-ProgressQueue) donde se reporta cada equipo que
        arranca y cada uno que termina.
      - El hilo de UI corre un DispatcherTimer cada 250 ms que (a) drena
        esa cola y (b) lee las lineas NUEVAS del archivo de log, y con eso
        pinta la consola, la barra de progreso y los contadores. De ahi que
        se vea avanzar en vivo en vez de quedarse mudo hasta el final.
      - "Detener" levanta el flag de cancelacion (-CancelFlag) que
        Invoke-ThrottledDeployment chequea en sus dos loops; los jobs se
        frenan desde adentro del runspace, que es el unico lugar donde
        Get-Job/Stop-Job los ve.

    El archivo de log se lee con FileShare.ReadWrite: los jobs siguen
    escribiendolo mientras la UI lo lee, asi que abrirlo en modo exclusivo
    romperia el despliegue entero.

    LAYOUT ADAPTABLE (ver seccion 2): la ventana se dimensiona en base al
    area de trabajo real del monitor, nunca con un tamano fijo, y todo el
    contenido vive dentro de UN UNICO SCROLL GENERAL. Los apartados (lista
    de equipos, parametros, ejecucion, progreso/consola) se apilan uno
    debajo del otro y se recorren con esa sola barra, como una pagina: no
    hay scrolls anidados ni secciones que se recorten.

    Este archivo es ASCII puro a proposito (sin tildes ni enies): evita por
    completo los problemas de encoding de PowerShell 5.1, que lee un .ps1
    sin BOM como ANSI en vez de UTF-8.

.EXAMPLE
    .\Deploy-Gui.ps1

.NOTES
    Requiere Windows con .NET/WPF y apartment STA. Si se arranca en MTA
    (por ejemplo pwsh 7 sin -STA), el script se relanza solo en STA.
#>
[CmdletBinding()]
param()

# ---------------------------------------------------------------------
# 0. Requisitos de plataforma
#
#    Esta interfaz esta hecha con WPF, que es exclusivo de Windows: los
#    ensamblados PresentationFramework/PresentationCore no existen en el
#    .NET de macOS ni de Linux. No es una limitacion del script, no hay
#    forma de abrir esta ventana fuera de Windows.
#
#    Ademas, fuera de Windows GetApartmentState() no devuelve "STA" sino
#    "Unknown". Sin el chequeo de SO, el script entraba en la rama de
#    relanzarse con -STA... y el proceso relanzado hacia exactamente lo
#    mismo: un bucle infinito de procesos. Por eso el orden importa: SO
#    primero, apartment despues, y el relanzamiento una sola vez.
# ---------------------------------------------------------------------
$esWindows = ($null -eq $PSVersionTable.Platform) -or ($PSVersionTable.Platform -eq 'Win32NT')

if (-not $esWindows) {
    Write-Host ""
    Write-Host "Deploy-Gui.ps1 solo corre en Windows." -ForegroundColor Yellow
    Write-Host "La interfaz usa WPF, que no existe en macOS ni en Linux." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Lo que SI se puede correr en esta maquina:" -ForegroundColor Cyan
    Write-Host "   pwsh ./tests/Test-DeploymentToolkit.ps1    (toda la logica del modulo)"
    Write-Host "   pwsh ./Deploy-Menu.ps1                     (el menu de consola)"
    Write-Host ""
    Write-Host "Ojo: psexec.exe y las rutas \\equipo\C$ tampoco existen fuera de"
    Write-Host "Windows, asi que el despliegue real necesita Windows igual."
    Write-Host ""
    return
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    # Guard de una sola vuelta: si el relanzamiento tampoco queda en STA,
    # se avisa en vez de volver a intentar para siempre.
    if ($env:DEPLOYGUI_RELANZADO -eq '1') {
        Write-Host "No se pudo arrancar en modo STA (WPF lo requiere). Proba:" -ForegroundColor Red
        Write-Host "   powershell.exe -STA -File .\Deploy-Gui.ps1" -ForegroundColor Red
        return
    }
    $hostExe = (Get-Process -Id $PID).Path
    Write-Host "Relanzando en modo STA (WPF lo requiere)..." -ForegroundColor Yellow
    $env:DEPLOYGUI_RELANZADO = '1'
    Start-Process -FilePath $hostExe -ArgumentList @(
        '-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    return
}

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:Root       = $PSScriptRoot
$script:ModulePath = Join-Path $script:Root 'Module\Deployment\Deployment.psd1'
Import-Module $script:ModulePath -Force

$script:Config = Get-DeploymentConfig -WarningAction SilentlyContinue

# ---------------------------------------------------------------------
# 1. Definicion de tareas
#
#    Viene del modulo (Get-DeploymentTaskCatalog), no de este archivo: la
#    interfaz web (Deploy-Web.ps1) lee exactamente el mismo catalogo, asi
#    que las dos no pueden quedar desincronizadas. Agregar una tarea se
#    hace una sola vez, en Public\Get-DeploymentTaskCatalog.ps1.
# ---------------------------------------------------------------------
$script:Tasks = Get-DeploymentTaskCatalog

# ---------------------------------------------------------------------
# 2. XAML
#
#    Reglas del layout, para que la ventana se adapte a cualquier pantalla:
#
#    - Ningun alto ni ancho fijo en la ventana: el tamano se calcula en
#      tiempo de ejecucion contra SystemParameters.WorkArea (seccion 11).
#      MinWidth/MinHeight son chicos a proposito, para que entre en
#      notebooks de 1366x768 y en pantallas con escalado al 150%.
#    - UN SOLO SCROLL GENERAL envuelve todo el contenido. Los apartados son
#      tarjetas apiladas en un StackPanel y se recorren con esa unica
#      barra. Nada de scrolls por seccion: una sola barra, como una pagina.
#    - Ese ScrollViewer va con HorizontalScrollBarVisibility=Disabled, que
#      ata el ancho del contenido al viewport: las tarjetas estiran y los
#      textos hacen wrap en vez de provocar scroll lateral.
#    - Excepcion necesaria: la consola (ListBox) lleva alto explicito,
#      recalculado con el alto de la ventana en Update-ConsoleHeight. Un
#      ListBox dentro de un scroll vertical recibe alto infinito y dejaria
#      de scrollear solo, volcando miles de lineas de log en la pagina.
#      El TextBox de pegar hostnames lleva alto fijo por lo mismo.
#    - Los controles de ancho fijo se reemplazaron por MinWidth/MaxWidth y
#      los grupos horizontales son WrapPanel, asi bajan de renglon en vez
#      de cortarse cuando la ventana es angosta.
# ---------------------------------------------------------------------
$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Deployment Toolkit"
        MinHeight="520" MinWidth="740"
        ResizeMode="CanResize"
        WindowStartupLocation="CenterScreen"
        Background="#F5F6F8" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="BrushRail"    Color="#1C1E22"/>
    <SolidColorBrush x:Key="BrushCard"    Color="#FFFFFF"/>
    <SolidColorBrush x:Key="BrushLine"    Color="#E2E4E9"/>
    <SolidColorBrush x:Key="BrushText"    Color="#1B1F24"/>
    <SolidColorBrush x:Key="BrushMuted"   Color="#6B7280"/>
    <SolidColorBrush x:Key="BrushAccent"  Color="#A11530"/>
    <SolidColorBrush x:Key="BrushOk"      Color="#2E7D32"/>
    <SolidColorBrush x:Key="BrushFail"    Color="#5B2A86"/>
    <SolidColorBrush x:Key="BrushConsole" Color="#12141A"/>

    <Style x:Key="CardStyle" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource BrushCard}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BrushLine}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="14"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>

    <Style x:Key="CardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#8A8F99"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>

    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#454B57"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>

    <Style x:Key="InputBox" TargetType="TextBox">
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Padding" Value="6,5"/>
      <Setter Property="BorderBrush" Value="#D7D9DE"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="HorizontalAlignment" Value="Stretch"/>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource BrushAccent}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,7"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#8D1129"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#C9CCD2"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
      <Setter Property="Background" Value="#EEF0F3"/>
      <Setter Property="Foreground" Value="#374151"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    BorderBrush="#D7D9DE" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E3E6EA"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#F3F4F6"/>
                <Setter Property="Foreground" Value="#A8ADB6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Los botones del rail se pintan por codigo (activo/inactivo), asi que
         necesitan un template que respete Background en vez del chrome por
         defecto del boton de Windows. -->
    <Style x:Key="RailButton" TargetType="Button">
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="HorizontalAlignment" Value="Stretch"/>
      <Setter Property="Padding" Value="10,8"/>
      <Setter Property="Margin" Value="0,0,0,2"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#B6BAC3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#25272C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="StatTile" TargetType="Border">
      <Setter Property="Background" Value="#F5F6F8"/>
      <Setter Property="BorderBrush" Value="#E6E8EC"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="7"/>
      <Setter Property="Padding" Value="12,8"/>
      <Setter Property="Margin" Value="0,0,8,6"/>
      <Setter Property="MinWidth" Value="92"/>
    </Style>

    <!-- OK y Fallidos son botones con la misma pinta que un StatTile: al
         hacer click abren el detalle por equipo. El estado "abierto" (borde
         de color) se pinta por codigo, ver Set-TileState. -->
    <Style x:Key="StatTileButton" TargetType="Button">
      <Setter Property="Background" Value="#F5F6F8"/>
      <Setter Property="BorderBrush" Value="#E6E8EC"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,8"/>
      <Setter Property="Margin" Value="0,0,8,6"/>
      <Setter Property="MinWidth" Value="92"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#ECEEF1"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Dos formas de acomodar el detalle: los OK son solo hostnames y van
         en grilla; los fallidos llevan el error al lado y van en lista. -->
    <ItemsPanelTemplate x:Key="PanelGrid"><WrapPanel Orientation="Horizontal"/></ItemsPanelTemplate>
    <ItemsPanelTemplate x:Key="PanelList"><VirtualizingStackPanel/></ItemsPanelTemplate>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border Grid.Row="0" Background="{StaticResource BrushRail}" Padding="14,9">
      <DockPanel LastChildFill="True">
        <TextBlock Text="Deployment Toolkit" Foreground="#DFE1E6" FontWeight="SemiBold"
                   VerticalAlignment="Center" DockPanel.Dock="Left"/>
        <TextBlock Text="-" Foreground="#4C505A" Margin="10,0" VerticalAlignment="Center" DockPanel.Dock="Left"/>
        <TextBlock x:Name="HeaderRoot" DockPanel.Dock="Right" HorizontalAlignment="Right"
                   Foreground="#5C616B" FontSize="11" FontFamily="Consolas" VerticalAlignment="Center"
                   TextTrimming="CharacterEllipsis" MaxWidth="460" Margin="12,0,0,0"/>
        <TextBlock x:Name="HeaderTask" Foreground="#8B8F99" VerticalAlignment="Center"
                   TextTrimming="CharacterEllipsis"/>
      </DockPanel>
    </Border>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto" MinWidth="150"/>
        <ColumnDefinition Width="*" MinWidth="420"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="{StaticResource BrushRail}" Width="188">
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="Rail" Margin="10,12"/>
        </ScrollViewer>
      </Border>

      <!-- UN SOLO SCROLL GENERAL para todo el contenido: los apartados se
           apilan uno debajo del otro y se recorren con esta unica barra,
           como una pagina. HorizontalScrollBarVisibility=Disabled hace que
           el ancho quede atado al viewport, asi las tarjetas estiran y los
           textos hacen wrap en vez de generar scroll lateral. -->
      <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto"
                    HorizontalScrollBarVisibility="Disabled" Padding="16,12,10,8">
        <StackPanel>

          <StackPanel Margin="0,0,0,10">
            <TextBlock x:Name="TaskTitle" FontSize="16" FontWeight="SemiBold"
                       Foreground="{StaticResource BrushText}" TextWrapping="Wrap"/>
            <TextBlock x:Name="TaskDesc" FontSize="12" Foreground="{StaticResource BrushMuted}"
                       TextWrapping="Wrap" Margin="0,3,0,0"/>
          </StackPanel>

          <Border Style="{StaticResource CardStyle}">
            <StackPanel>
              <TextBlock Text="LISTA DE EQUIPOS" Style="{StaticResource CardTitle}"/>
              <WrapPanel>
                <RadioButton x:Name="RbFile" Content="Archivo de imports\" IsChecked="True"
                             VerticalAlignment="Center" GroupName="src" Margin="0,0,10,6"/>
                <ComboBox x:Name="ImportCombo" MinWidth="190" MaxWidth="320" VerticalAlignment="Center"
                          FontFamily="Consolas" FontSize="12" Margin="0,0,18,6"/>
                <RadioButton x:Name="RbPaste" Content="Pegar hostnames" VerticalAlignment="Center"
                             GroupName="src" Margin="0,0,14,6"/>
                <Button x:Name="BtnReload" Content="Recargar" Style="{StaticResource GhostButton}"
                        Padding="12,5" Margin="0,0,8,6"/>
                <Button x:Name="BtnOpenImports" Content="Abrir carpeta" Style="{StaticResource GhostButton}"
                        Padding="12,5" Margin="0,0,0,6"/>
              </WrapPanel>
              <!-- Ruta REAL que se esta leyendo. Sin esto, un "0 equipos" no
                   distingue entre archivo vacio, archivo equivocado o carpeta
                   imports\ resuelta a otro lado. -->
              <TextBlock x:Name="PathText" Margin="0,6,0,0" FontSize="11" FontFamily="Consolas"
                         Foreground="#9AA1AD" TextWrapping="Wrap"/>
              <TextBox x:Name="PasteBox" Style="{StaticResource InputBox}" Height="80"
                       Margin="0,6,0,0" AcceptsReturn="True" TextWrapping="NoWrap" Visibility="Collapsed"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
              <TextBlock x:Name="CountText" Margin="0,8,0,0" FontSize="12.5"
                         Foreground="{StaticResource BrushText}" TextWrapping="Wrap"/>
              <TextBlock x:Name="PreviewText" Margin="0,4,0,0" FontSize="11.5" FontFamily="Consolas"
                         Foreground="#6B7280" TextWrapping="Wrap"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource CardStyle}">
            <StackPanel>
              <TextBlock Text="PARAMETROS" Style="{StaticResource CardTitle}"/>
              <StackPanel x:Name="ParamPanel"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource CardStyle}">
            <StackPanel>
              <TextBlock Text="EJECUCION" Style="{StaticResource CardTitle}"/>
              <WrapPanel>
                <TextBlock Text="Throttle limit" Style="{StaticResource FieldLabel}"
                           VerticalAlignment="Center" Margin="0,0,8,4"/>
                <TextBox x:Name="ThrottleBox" Style="{StaticResource InputBox}" Width="54"
                         HorizontalAlignment="Left" VerticalAlignment="Center" Margin="0,0,18,4"/>
                <Button x:Name="BtnRun" Content="Ejecutar" Style="{StaticResource PrimaryButton}" Margin="0,0,8,4"/>
                <Button x:Name="BtnStop" Content="Detener" Style="{StaticResource GhostButton}"
                        IsEnabled="False" Margin="0,0,14,4"/>
                <TextBlock x:Name="LogHint" VerticalAlignment="Center" FontSize="11" FontFamily="Consolas"
                           Foreground="#9AA1AD" TextTrimming="CharacterEllipsis" Margin="0,0,0,4"/>
              </WrapPanel>
              <TextBlock x:Name="ValidationText" Margin="0,6,0,0" FontSize="12" Foreground="#5B2A86"
                         TextWrapping="Wrap" Visibility="Collapsed"/>
            </StackPanel>
          </Border>

          <Border Style="{StaticResource CardStyle}">
            <StackPanel>
              <TextBlock Text="PROGRESO Y CONSOLA EN VIVO" Style="{StaticResource CardTitle}"/>

              <DockPanel Margin="0,0,0,10">
                <TextBlock x:Name="ProgText" DockPanel.Dock="Left" MinWidth="104" FontSize="11.5"
                           Foreground="{StaticResource BrushMuted}" VerticalAlignment="Center"
                           TextTrimming="CharacterEllipsis" Margin="0,0,10,0"/>
                <ProgressBar x:Name="Prog" Height="7" Minimum="0" Maximum="100" Value="0"
                             Foreground="{StaticResource BrushAccent}" Background="#E6E8EC" BorderThickness="0"/>
              </DockPanel>

              <WrapPanel Margin="0,0,0,6">
                <Border Style="{StaticResource StatTile}">
                  <StackPanel>
                    <TextBlock x:Name="TotalText" Text="0" FontSize="18" FontWeight="Bold"
                               Foreground="{StaticResource BrushText}"/>
                    <TextBlock Text="TOTAL" FontSize="10.5" FontWeight="SemiBold" Foreground="#8A8F99"/>
                  </StackPanel>
                </Border>
                <Button x:Name="TileOk" Style="{StaticResource StatTileButton}"
                        ToolTip="Ver los equipos que terminaron OK">
                  <StackPanel>
                    <TextBlock x:Name="OkText" Text="0" FontSize="18" FontWeight="Bold"
                               Foreground="{StaticResource BrushOk}"/>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="OK" FontSize="10.5" FontWeight="SemiBold" Foreground="#8A8F99"/>
                      <Path x:Name="OkChevron" Data="M0,0 L3.5,3.5 L7,0" Stroke="#8A8F99" StrokeThickness="1.5"
                            Width="8" Height="5" Margin="6,1,0,0" VerticalAlignment="Center"
                            RenderTransformOrigin="0.5,0.5"/>
                    </StackPanel>
                  </StackPanel>
                </Button>
                <Button x:Name="TileFail" Style="{StaticResource StatTileButton}"
                        ToolTip="Ver los equipos que fallaron y su error">
                  <StackPanel>
                    <TextBlock x:Name="FailText" Text="0" FontSize="18" FontWeight="Bold"
                               Foreground="{StaticResource BrushFail}"/>
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="FALLIDOS" FontSize="10.5" FontWeight="SemiBold" Foreground="#8A8F99"/>
                      <Path x:Name="FailChevron" Data="M0,0 L3.5,3.5 L7,0" Stroke="#8A8F99" StrokeThickness="1.5"
                            Width="8" Height="5" Margin="6,1,0,0" VerticalAlignment="Center"
                            RenderTransformOrigin="0.5,0.5"/>
                    </StackPanel>
                  </StackPanel>
                </Button>
                <Button x:Name="BtnOpenLog" Content="Abrir log completo" Style="{StaticResource GhostButton}"
                        Padding="12,6" VerticalAlignment="Center" Margin="0,0,8,6"/>
                <Button x:Name="BtnClear" Content="Limpiar consola" Style="{StaticResource GhostButton}"
                        Padding="12,6" VerticalAlignment="Center" Margin="0,0,0,6"/>
              </WrapPanel>

              <!-- Detalle por equipo: se abre con click en OK o en Fallidos.
                   MaxHeight porque esta dentro del scroll general (mismo
                   motivo que el alto explicito de la consola). -->
              <Border x:Name="DetailPanel" Visibility="Collapsed" Background="#FAFBFC"
                      BorderBrush="#E2E4E9" BorderThickness="1" CornerRadius="7" Margin="0,0,0,10">
                <StackPanel Grid.IsSharedSizeScope="True">
                  <Border BorderBrush="#E6E8EC" BorderThickness="0,0,0,1" Padding="10,7">
                    <DockPanel LastChildFill="False">
                      <TextBlock x:Name="DetailTitle" DockPanel.Dock="Left" FontSize="11" FontWeight="Bold"
                                 VerticalAlignment="Center"/>
                      <Border DockPanel.Dock="Left" Background="#EEF0F3" CornerRadius="9" Padding="7,1"
                              Margin="8,0,0,0" VerticalAlignment="Center">
                        <TextBlock x:Name="DetailCount" Text="0" FontSize="11" FontWeight="SemiBold" Foreground="#6B7280"/>
                      </Border>
                      <Button x:Name="BtnCloseDetail" DockPanel.Dock="Right" Content="Cerrar"
                              Style="{StaticResource GhostButton}" Padding="10,3" FontSize="11.5"/>
                      <Button x:Name="BtnCopyDetail" DockPanel.Dock="Right" Content="Copiar hostnames"
                              Style="{StaticResource GhostButton}" Padding="10,3" FontSize="11.5" Margin="0,0,6,0"
                              ToolTip="Copia solo los hostnames, uno por linea"/>
                    </DockPanel>
                  </Border>
                  <Grid x:Name="DetailHeader" Margin="11,6,12,2" Visibility="Collapsed">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto" SharedSizeGroup="Host"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="HOSTNAME" FontSize="10.5" FontWeight="Bold" Foreground="#8A8F99"
                               Margin="0,0,14,0"/>
                    <TextBlock Grid.Column="1" Text="ERROR" FontSize="10.5" FontWeight="Bold" Foreground="#8A8F99"/>
                  </Grid>
                  <TextBlock x:Name="DetailEmpty" Margin="12,8" FontSize="12.5" Foreground="#6B7280"
                             TextWrapping="Wrap" Visibility="Collapsed"/>
                  <ListBox x:Name="DetailList" MaxHeight="260" BorderThickness="0" Background="Transparent"
                           Margin="4,2,4,6" HorizontalContentAlignment="Stretch"
                           ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                           ScrollViewer.VerticalScrollBarVisibility="Auto">
                    <ListBox.ItemContainerStyle>
                      <Style TargetType="ListBoxItem">
                        <Setter Property="Padding" Value="6,3"/>
                        <Setter Property="BorderThickness" Value="0"/>
                        <Setter Property="Background" Value="Transparent"/>
                      </Style>
                    </ListBox.ItemContainerStyle>
                  </ListBox>
                </StackPanel>
              </Border>

              <!-- Alto explicito (se recalcula con la ventana, ver Update-ConsoleHeight):
                   adentro de un scroll vertical, WPF le daria alto infinito al
                   ListBox, renderizaria las miles de lineas del log de una y
                   dejaria de scrollear solo. -->
              <ListBox x:Name="LogList" Height="300" Background="{StaticResource BrushConsole}"
                       BorderThickness="0" FontFamily="Consolas" FontSize="12"
                       ScrollViewer.HorizontalScrollBarVisibility="Auto"
                       ScrollViewer.VerticalScrollBarVisibility="Auto"
                       VirtualizingStackPanel.IsVirtualizing="True"
                       VirtualizingStackPanel.VirtualizationMode="Recycling">
                <ListBox.ItemContainerStyle>
                  <Style TargetType="ListBoxItem">
                    <Setter Property="Padding" Value="4,1"/>
                    <Setter Property="BorderThickness" Value="0"/>
                    <Setter Property="Background" Value="Transparent"/>
                  </Style>
                </ListBox.ItemContainerStyle>
              </ListBox>
            </StackPanel>
          </Border>

        </StackPanel>
      </ScrollViewer>
    </Grid>

    <Border Grid.Row="2" Background="#ECEEF1" BorderBrush="{StaticResource BrushLine}"
            BorderThickness="0,1,0,0" Padding="14,5">
      <TextBlock x:Name="StatusText" VerticalAlignment="Center" FontSize="11"
                 Foreground="#6B7280" TextTrimming="CharacterEllipsis"/>
    </Border>
  </Grid>
</Window>
'@

[xml]$xamlDoc = $xamlText
$reader = New-Object System.Xml.XmlNodeReader $xamlDoc
$window = [Windows.Markup.XamlReader]::Load($reader)

foreach ($name in @('Rail','HeaderTask','HeaderRoot','TaskTitle','TaskDesc','RbFile','RbPaste','ImportCombo',
                    'BtnReload','BtnOpenImports','PasteBox','CountText','PreviewText','PathText','ParamPanel','ThrottleBox','BtnRun','BtnStop',
                    'ValidationText','ProgText','Prog','TotalText','OkText','FailText','BtnOpenLog','BtnClear',
                    'LogList','StatusText','LogHint',
                    'TileOk','TileFail','OkChevron','FailChevron','DetailPanel','DetailTitle','DetailCount',
                    'DetailHeader','DetailEmpty','DetailList','BtnCopyDetail','BtnCloseDetail')) {
    Set-Variable -Name $name -Scope Script -Value $window.FindName($name)
}

# ---------------------------------------------------------------------
# 3. Estado
# ---------------------------------------------------------------------
$script:CurrentTask   = $null
$script:FieldControls = @{}
$script:Running       = $false
$script:Sync          = $null
$script:PsWorker      = $null
$script:Handle        = $null
$script:Timer         = $null
$script:LogOffset     = 0
$script:LogCarry      = ''
$script:CurrentLog    = $null
$script:Ok            = 0
$script:Fail          = 0
$script:DoneCount     = 0
$script:TotalCount    = 0
$script:FlushTicks    = 0

# Detalle por equipo para los paneles de OK / Fallidos. Se llenan en vivo
# con cada JobDone y, al terminar, se reemplazan por el resumen final del
# modulo (que para un job caido trae el error real, no el generico "sin
# resultado" que ve el peek en vivo). OJO: no usar @($script:FailList): en
# PowerShell 7.4, @() sobre un List[object] con pscustomobject adentro
# truena con "Argument types do not match". foreach o .ToArray().
$script:OkList     = New-Object 'System.Collections.Generic.List[string]'
$script:FailList   = New-Object 'System.Collections.Generic.List[object]'
$script:DetailMode = $null      # $null | 'ok' | 'fail'
$script:HasRun     = $false
$script:CopyTimer  = $null

$BrushMap = @{
    ok      = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#56D364')
    fail    = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#B28CF0')
    warn    = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFCF6B')
    muted   = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#7D8590')
    normal  = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#C9CDD6')
    summary = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E7E9EE')
}

# ---------------------------------------------------------------------
# 4. Consola
# ---------------------------------------------------------------------
function Add-ConsoleLine {
    param([string]$Text, [string]$Kind = 'normal')

    $item = New-Object System.Windows.Controls.ListBoxItem
    $item.Content = $Text
    $item.Foreground = $BrushMap[$Kind]
    if ($Kind -eq 'summary') { $item.FontWeight = 'Bold' }
    [void]$script:LogList.Items.Add($item)

    # Tope del buffer visible: un despliegue a cientos de equipos genera
    # miles de lineas y el ListBox se vuelve lento. El log completo sigue
    # entero en disco (boton "Abrir log completo").
    while ($script:LogList.Items.Count -gt 900) {
        $script:LogList.Items.RemoveAt(0)
    }
    $script:LogList.ScrollIntoView($script:LogList.Items[$script:LogList.Items.Count - 1])
}

# La consola esta dentro del scroll general, asi que necesita un alto
# explicito: un ListBox dentro de un ScrollViewer vertical recibe alto
# infinito, renderiza todas las lineas de una y deja de scrollear solo. Se
# recalcula con el alto de la ventana para que aproveche las pantallas
# grandes sin quedar desproporcionada en las chicas.
function Update-ConsoleHeight {
    $h = $window.ActualHeight
    if (-not $h -or $h -le 0) { $h = $window.Height }
    if (-not $h -or $h -le 0) { return }
    $script:LogList.Height = [Math]::Max(200, [Math]::Round($h * 0.40))
}

function Get-LineKind {
    param([string]$Line)
    switch -Regex ($Line) {
        'RESUMEN|INIT \||FIN \|'                           { return 'summary' }
        'ERROR|FAIL|No Instalado|no actualizado|CANCELADO' { return 'fail' }
        'OK:|Ping OK|Completed|correctamente'              { return 'ok' }
        'INSTALANDO|Ejecutando:|Copiando|Consultando'      { return 'warn' }
        default                                            { return 'normal' }
    }
}

# Lee SOLO lo que se agrego al log desde la ultima vuelta. Se abre con
# FileShare.ReadWrite porque los jobs lo estan escribiendo al mismo tiempo:
# abrirlo en modo exclusivo desde aca haria fallar sus Add-Content.
function Read-NewLogLines {
    if (-not $script:CurrentLog -or -not (Test-Path $script:CurrentLog)) { return @() }

    $lines = @()
    try {
        $fs = New-Object System.IO.FileStream(
            $script:CurrentLog,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        try {
            if ($fs.Length -lt $script:LogOffset) {
                # El log fue truncado o rotado: volver a empezar.
                $script:LogOffset = 0
                $script:LogCarry = ''
            }
            [void]$fs.Seek($script:LogOffset, [System.IO.SeekOrigin]::Begin)
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $chunk = $sr.ReadToEnd()
            $script:LogOffset = $fs.Position

            if ($chunk) {
                $chunk = $script:LogCarry + $chunk
                $script:LogCarry = ''
                # Si el chunk no termina en salto de linea, la ultima linea
                # viene cortada a la mitad (un job estaba escribiendo justo
                # en ese momento): se guarda para completarla en la proxima
                # vuelta en vez de pintarla partida.
                if (-not ($chunk.EndsWith("`n"))) {
                    $idx = $chunk.LastIndexOf("`n")
                    if ($idx -ge 0) {
                        $script:LogCarry = $chunk.Substring($idx + 1)
                        $chunk = $chunk.Substring(0, $idx + 1)
                    }
                    else {
                        $script:LogCarry = $chunk
                        $chunk = ''
                    }
                }
                if ($chunk) {
                    $lines = @($chunk -split "`r?`n" | Where-Object { $_ -ne '' })
                }
            }
        }
        finally { $fs.Dispose() }
    }
    catch {
        # Un fallo leyendo el log no puede tumbar la UI ni el despliegue.
    }
    return $lines
}

# ---------------------------------------------------------------------
# 5. Lista de equipos
# ---------------------------------------------------------------------
function Update-ImportCombo {
    $script:ImportCombo.Items.Clear()

    $folder = $script:Config.ImportsPath
    $files = @()
    if ($folder -and (Test-Path $folder)) {
        $files = @(Get-ChildItem -Path $folder -Filter '*.txt' -ErrorAction SilentlyContinue | Sort-Object Name)
    }
    foreach ($f in $files) { [void]$script:ImportCombo.Items.Add($f.Name) }

    if ($script:CurrentTask -and $script:ImportCombo.Items.Contains($script:CurrentTask.ImportFile)) {
        $script:ImportCombo.SelectedItem = $script:CurrentTask.ImportFile
    }
    elseif ($script:ImportCombo.Items.Count -gt 0) {
        $script:ImportCombo.SelectedIndex = 0
    }
}

# Devuelve SIEMPRE un objeto con List / Path / Error.
#
# Antes esta funcion atrapaba cualquier excepcion y devolvia una lista
# vacia en silencio: un archivo inexistente, una carpeta imports\ resuelta
# a otro lado, un permiso denegado o un archivo realmente vacio se veian
# todos igual, como un escueto "0 equipos" sin decir por que. Ahora el
# motivo viaja hasta la pantalla.
function Resolve-ComputerList {
    if ($script:RbPaste.IsChecked) {
        $raw = $script:PasteBox.Text -split "[`r`n,;\s]+"
        $list = @($raw | ForEach-Object { $_.Trim().Trim('"').Trim("'") } |
                  Where-Object { $_ -ne '' -and -not $_.StartsWith('#') } |
                  Select-Object -Unique)
        return [pscustomobject]@{ List = $list; Path = '(hostnames pegados a mano)'; Error = $null }
    }

    $folder = $script:Config.ImportsPath

    if (-not $folder -or -not (Test-Path $folder)) {
        return [pscustomobject]@{
            List  = @()
            Path  = $folder
            Error = "No existe la carpeta de imports: $folder"
        }
    }

    if (-not $script:ImportCombo.SelectedItem) {
        return [pscustomobject]@{
            List  = @()
            Path  = $folder
            Error = "No hay ningun archivo .txt en $folder (o ninguno seleccionado)."
        }
    }

    $path = Join-Path $folder $script:ImportCombo.SelectedItem
    try {
        # Misma funcion que usan el menu y los scripts: recorta, descarta
        # vacias y comentarios, deduplica.
        $list = @(Read-ComputerList -Path $path -WarningAction SilentlyContinue)
        return [pscustomobject]@{ List = $list; Path = $path; Error = $null }
    }
    catch {
        return [pscustomobject]@{ List = @(); Path = $path; Error = $_.Exception.Message }
    }
}

function Update-ComputerPreview {
    $r = Resolve-ComputerList

    $script:CountText.Text = "$($r.List.Count) equipos seleccionados"
    $script:PathText.Text  = "Leyendo: $($r.Path)"

    if ($r.Error) {
        $script:PreviewText.Text = "PROBLEMA: $($r.Error)"
        $script:PreviewText.Foreground = $BrushMap['fail']
    }
    elseif ($r.List.Count -eq 0) {
        $script:PreviewText.Text = 'El archivo existe pero no tiene hostnames: solo lineas vacias o comentarios. Reviso ese archivo, no otro.'
        $script:PreviewText.Foreground = $BrushMap['fail']
    }
    else {
        $preview = ($r.List | Select-Object -First 6) -join '   '
        if ($r.List.Count -gt 6) { $preview += "   ... +$($r.List.Count - 6) mas" }
        $script:PreviewText.Text = $preview
        $script:PreviewText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#6B7280')
    }
}

# ---------------------------------------------------------------------
# 6. Formulario dinamico
# ---------------------------------------------------------------------
function Build-ParameterPanel {
    param($Task)

    $script:ParamPanel.Children.Clear()
    $script:FieldControls = @{}

    if ($Task.Fields.Count -eq 0) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = 'Esta tarea no tiene parametros propios: solo dispara el scan en cada equipo de la lista.'
        $tb.FontSize = 12.5
        $tb.TextWrapping = 'Wrap'
        $tb.Foreground = $BrushMap['muted']
        [void]$script:ParamPanel.Children.Add($tb)
        return
    }

    foreach ($field in $Task.Fields) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Margin = '0,0,0,10'

        if ($field.Type -in @('Switch', 'Bool', 'BoolArr')) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $field.Label
            $cb.IsChecked = [bool]$field.Default
            $cb.FontSize = 12.5
            [void]$row.Children.Add($cb)
            $script:FieldControls[$field.Name] = $cb
        }
        else {
            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = if ($field.Hint) { "$($field.Label)  ($($field.Hint))" } else { $field.Label }
            $lbl.Style = $window.FindResource('FieldLabel')
            [void]$row.Children.Add($lbl)

            $tb = New-Object System.Windows.Controls.TextBox
            $tb.Style = $window.FindResource('InputBox')
            $tb.Text = [string]$field.Default
            # Sin anchos fijos: todo estira con la ventana. Los campos
            # cortos llevan un tope para no quedar absurdamente largos en
            # pantallas grandes, pero se achican sin recortarse.
            $tb.HorizontalAlignment = 'Stretch'
            if (-not $field.Wide) { $tb.MaxWidth = 420 }
            [void]$row.Children.Add($tb)
            $script:FieldControls[$field.Name] = $tb
        }

        [void]$script:ParamPanel.Children.Add($row)
    }
}

# Traduce el formulario a los parametros reales de la funcion del modulo.
function Read-ParameterValues {
    param($Task)

    $splat = @{}
    foreach ($field in $Task.Fields) {
        $ctrl = $script:FieldControls[$field.Name]
        switch ($field.Type) {
            'Switch'  { if ($ctrl.IsChecked) { $splat[$field.Name] = $true } }
            'Bool'    { $splat[$field.Name] = [bool]$ctrl.IsChecked }
            'BoolArr' { $splat[$field.Name] = [bool[]]@([bool]$ctrl.IsChecked) }
            'List'    { $splat[$field.Name] = @($ctrl.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }
            'Codes'   { $splat[$field.Name] = [int[]]@($ctrl.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }) }
            'TextArr' { $splat[$field.Name] = @($ctrl.Text.Trim()) }
            'Int'     { if ($ctrl.Text.Trim()) { $splat[$field.Name] = [int]$ctrl.Text.Trim() } }
            'Minutes' {
                # La UI pide minutos porque es como se piensa la tarea; el
                # modulo espera SEGUNDOS (fue justamente una confusion de
                # unidades la que dejo un "timeout de 10 minutos" valiendo
                # 600 ms en la version vieja, ver CHANGES.md 1.8).
                $m = 0
                if ($ctrl.Text.Trim()) { $m = [int]$ctrl.Text.Trim() }
                $splat[$field.Name] = $m * 60
            }
            default   { if ($ctrl.Text.Trim()) { $splat[$field.Name] = $ctrl.Text.Trim() } }
        }
    }
    return $splat
}

function Test-Parameters {
    param($Task, $ComputerList)

    $errors = @()
    if ($ComputerList.Count -eq 0) {
        $errors += 'No hay equipos seleccionados.'
    }

    foreach ($field in $Task.Fields) {
        $ctrl = $script:FieldControls[$field.Name]
        if ($field.Type -in @('Switch', 'Bool', 'BoolArr')) { continue }

        $value = $ctrl.Text.Trim()
        if ($field.Required -and -not $value) {
            $errors += "Falta completar: $($field.Label)."
            continue
        }
        if ($value -and $field.Pattern -and ($value -notmatch $field.Pattern)) {
            $errors += "$($field.Label): $($field.PatternMsg)"
        }
    }

    # Regla propia de Invoke-RemoteCommand: -CompareVersion exige
    # -MinVersion. Se valida aca para avisar antes de arrancar, en vez de
    # dejar que la funcion lance la excepcion con el despliegue ya lanzado.
    if ($Task.Id -eq 'remotecmd') {
        $cmp = $script:FieldControls['CompareVersion']
        $min = $script:FieldControls['MinVersion']
        if ($cmp.IsChecked -and -not $min.Text.Trim()) {
            $errors += 'Comparar version requiere que completes la version minima.'
        }
    }

    # Regla propia de Invoke-OfficeUpdate: o hay version minima con la cual
    # comparar, o se pide explicitamente forzar. Sin ninguna de las dos no
    # hay criterio para decidir que equipos actualizar.
    if ($Task.Id -eq 'office') {
        $force  = $script:FieldControls['ForceUpdate']
        $target = $script:FieldControls['TargetVersion']
        if (-not $force.IsChecked -and -not $target.Text.Trim()) {
            $errors += 'Indica la version minima esperada, o tilda "Forzar actualizacion" para actualizar todos sin comparar.'
        }
    }

    $throttle = 0
    if (-not [int]::TryParse($script:ThrottleBox.Text.Trim(), [ref]$throttle) -or $throttle -lt 1) {
        $errors += 'El throttle limit tiene que ser un numero mayor o igual a 1.'
    }

    return $errors
}

# ---------------------------------------------------------------------
# 7. Navegacion
# ---------------------------------------------------------------------
function Select-Task {
    param([string]$TaskId)

    if ($script:Running) { return }

    $task = $script:Tasks | Where-Object { $_.Id -eq $TaskId } | Select-Object -First 1
    if (-not $task) { return }

    $script:CurrentTask = $task
    $script:HeaderTask.Text = $task.Label
    $script:TaskTitle.Text  = $task.Label
    $script:TaskDesc.Text   = $task.Desc
    $script:ThrottleBox.Text = [string]$task.Throttle
    $script:CurrentLog = Join-Path $script:Config.LogsPath $task.LogFile
    $script:LogHint.Text = "logs\$($task.LogFile)"

    foreach ($child in $script:Rail.Children) {
        $isActive = ($child.Tag -eq $TaskId)
        $child.Background = if ($isActive) {
            [System.Windows.Media.BrushConverter]::new().ConvertFromString('#33131A')
        } else {
            [System.Windows.Media.Brushes]::Transparent
        }
        $child.Foreground = if ($isActive) {
            [System.Windows.Media.Brushes]::White
        } else {
            [System.Windows.Media.BrushConverter]::new().ConvertFromString('#B6BAC3')
        }
    }

    Update-ImportCombo
    Build-ParameterPanel -Task $task
    Update-ComputerPreview
    # Tarea nueva: los contadores vuelven a 0, asi que el detalle tambien
    # (y si quedo abierto, dice que todavia no se corrio nada).
    $script:HasRun = $false
    Reset-RunState
    $script:ValidationText.Visibility = 'Collapsed'
    $script:StatusText.Text = "Listo. Funcion del modulo: $($task.Function)"
}

function Build-Rail {
    $script:Rail.Children.Clear()
    foreach ($task in $script:Tasks) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $window.FindResource('RailButton')
        $btn.Content = $task.Label
        $btn.Tag = $task.Id

        # Se captura el id en una variable propia y se cierra sobre ella
        # (GetNewClosure). Usar $this.Tag dentro del handler es fragil
        # cuando el scriptblock es una closure: el id queda fijado aca.
        $taskId = $task.Id
        $btn.Add_Click({ Select-Task -TaskId $taskId }.GetNewClosure())

        [void]$script:Rail.Children.Add($btn)
    }
}

# ---------------------------------------------------------------------
# 8. Ejecucion
# ---------------------------------------------------------------------
function Reset-RunState {
    $script:Ok = 0; $script:Fail = 0; $script:DoneCount = 0; $script:TotalCount = 0
    $script:OkText.Text = '0'
    $script:FailText.Text = '0'
    $script:TotalText.Text = '0'
    $script:Prog.Value = 0
    $script:ProgText.Text = '0 / 0 equipos'
    $script:OkList.Clear()
    $script:FailList.Clear()
    if ($script:DetailMode) { Update-DetailPanel }
}

function Start-Deployment {
    if ($script:Running) { return }

    $task = $script:CurrentTask
    $computers = (Resolve-ComputerList).List

    $errors = Test-Parameters -Task $task -ComputerList $computers
    if ($errors.Count -gt 0) {
        $script:ValidationText.Text = ($errors -join "   |   ")
        $script:ValidationText.Visibility = 'Visible'
        return
    }
    $script:ValidationText.Visibility = 'Collapsed'

    $answer = [System.Windows.MessageBox]::Show(
        "Ejecutar '$($task.Label)' en $($computers.Count) equipos?",
        'Confirmar ejecucion',
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $splat = Read-ParameterValues -Task $task
    $splat['ComputerList']  = $computers
    $splat['ThrottleLimit'] = [int]$script:ThrottleBox.Text.Trim()
    $splat['LogPath']       = $script:CurrentLog

    Reset-RunState
    $script:LogList.Items.Clear()
    $script:TotalCount = $computers.Count
    $script:TotalText.Text = [string]$computers.Count
    $script:ProgText.Text = "0 / $($computers.Count) equipos"

    # Arrancar a leer el log desde el final actual: solo interesan las
    # lineas de ESTA corrida, no el historico del archivo.
    $script:LogOffset = 0
    $script:LogCarry = ''
    if (Test-Path $script:CurrentLog) {
        $script:LogOffset = (Get-Item $script:CurrentLog).Length
    }

    Add-ConsoleLine "=== $($task.Label) - $($computers.Count) equipos - throttle $($splat['ThrottleLimit']) ===" 'summary'
    Add-ConsoleLine "Llamando a $($task.Function) del modulo Deployment" 'muted'

    $script:Sync = [hashtable]::Synchronized(@{})
    $script:Sync.Queue   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:Sync.Cancel  = [hashtable]::Synchronized(@{ Cancel = $false })
    $script:Sync.Summary = $null
    $script:Sync.Error   = $null

    $worker = {
        param($ModulePath, $FunctionName, $Splat, $Sync)
        try {
            Import-Module $ModulePath -Force -ErrorAction Stop
            $Splat['ProgressQueue'] = $Sync.Queue
            $Splat['CancelFlag']    = $Sync.Cancel
            $Sync.Summary = & $FunctionName @Splat
        }
        catch {
            $Sync.Error = $_.Exception.Message
            $Sync.Queue.Enqueue([pscustomobject]@{ Type = 'Error'; Message = $_.Exception.Message })
        }
        finally {
            $Sync.Queue.Enqueue([pscustomobject]@{ Type = 'WorkerDone' })
        }
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions  = 'ReuseThread'
    $runspace.Open()

    $script:PsWorker = [powershell]::Create()
    $script:PsWorker.Runspace = $runspace
    [void]$script:PsWorker.AddScript($worker).
        AddArgument($script:ModulePath).
        AddArgument($task.Function).
        AddArgument($splat).
        AddArgument($script:Sync)
    $script:Handle = $script:PsWorker.BeginInvoke()

    $script:Running = $true
    $script:HasRun = $true
    if ($script:DetailMode) { Update-DetailPanel }   # el panel abierto arranca vacio y se llena en vivo
    $script:FlushTicks = 0
    $script:BtnRun.IsEnabled = $false
    $script:BtnStop.IsEnabled = $true
    $script:Rail.IsEnabled = $false
    $script:StatusText.Text = "Ejecutando $($task.Function) en $($computers.Count) equipos..."

    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:Timer.Add_Tick({ Update-FromWorker })
    $script:Timer.Start()
}

function Update-FromWorker {
    # (a) Drenar la cola de progreso que llena Invoke-ThrottledDeployment.
    $workerDone = $false
    $item = $null
    while ($script:Sync.Queue.TryDequeue([ref]$item)) {
        switch ($item.Type) {
            'JobStart' {
                $script:StatusText.Text = "Encolando: $($item.Equipo)  ($($item.Started)/$($item.Total))"
            }
            'JobDone' {
                $script:DoneCount = $item.Done
                if ($item.Success) {
                    $script:Ok++
                    $script:OkList.Add([string]$item.Equipo)
                    if ($script:DetailMode -eq 'ok') {
                        [void]$script:DetailList.Items.Add((New-DetailItem -Equipo $item.Equipo))
                        Update-DetailCount
                    }
                }
                else {
                    $script:Fail++
                    $entry = [pscustomobject]@{ Equipo = [string]$item.Equipo; Message = [string]$item.Message }
                    $script:FailList.Add($entry)
                    if ($script:DetailMode -eq 'fail') {
                        [void]$script:DetailList.Items.Add((New-DetailItem -Equipo $entry.Equipo -Mensaje $entry.Message -Fail))
                        Update-DetailCount
                    }
                }
                $script:OkText.Text   = [string]$script:Ok
                $script:FailText.Text = [string]$script:Fail
                $script:ProgText.Text = "$($script:DoneCount) / $($script:TotalCount) equipos"
                if ($script:TotalCount -gt 0) {
                    $script:Prog.Value = [math]::Round(($script:DoneCount / $script:TotalCount) * 100)
                }
            }
            'BatchEnd' {
                if ($item.Cancelled) { Add-ConsoleLine '*** Cancelado por el usuario ***' 'fail' }
            }
            'Error' {
                Add-ConsoleLine "ERROR: $($item.Message)" 'fail'
            }
            'WorkerDone' { $workerDone = $true }
        }
    }

    # (b) Volcar las lineas nuevas del archivo de log.
    foreach ($line in (Read-NewLogLines)) {
        Add-ConsoleLine $line (Get-LineKind $line)
    }

    if ($workerDone) {
        # Unas vueltas mas para alcanzar a leer lo ultimo que los jobs
        # escribieron justo antes de terminar.
        $script:FlushTicks = 4
    }
    if ($script:FlushTicks -gt 0) {
        $script:FlushTicks--
        if ($script:FlushTicks -eq 0) { Complete-Deployment }
    }
}

function Complete-Deployment {
    if ($script:Timer) { $script:Timer.Stop(); $script:Timer = $null }

    foreach ($line in (Read-NewLogLines)) {
        Add-ConsoleLine $line (Get-LineKind $line)
    }

    try {
        if ($script:PsWorker -and $script:Handle) {
            [void]$script:PsWorker.EndInvoke($script:Handle)
        }
    }
    catch {
        Add-ConsoleLine "ERROR al cerrar el worker: $($_.Exception.Message)" 'fail'
    }
    finally {
        if ($script:PsWorker) {
            if ($script:PsWorker.Runspace) { $script:PsWorker.Runspace.Dispose() }
            $script:PsWorker.Dispose()
            $script:PsWorker = $null
        }
        $script:Handle = $null
    }

    $summary = $script:Sync.Summary
    if ($summary) {
        # El resumen final es la fuente de verdad del detalle: se reemplaza
        # lo acumulado en vivo (mismo criterio que Deploy-Web.ps1).
        $script:OkList.Clear()
        foreach ($r in @($summary.Succeeded)) { if ($r) { $script:OkList.Add([string]$r.Equipo) } }
        $script:FailList.Clear()
        foreach ($e in @($summary.Errors)) {
            if ($e) { $script:FailList.Add([pscustomobject]@{ Equipo = [string]$e.Equipo; Message = [string]$e.Message }) }
        }
        $script:Ok = $script:OkList.Count
        $script:Fail = $script:FailList.Count
        $script:OkText.Text   = [string]$script:Ok
        $script:FailText.Text = [string]$script:Fail

        Add-ConsoleLine ("RESUMEN | Total={0} OK={1} Fallidos={2}" -f $summary.Total, $summary.Ok, $summary.Failed) 'summary'
        foreach ($e in @($summary.Errors)) {
            if ($e) { Add-ConsoleLine ("  - {0}  {1}" -f $e.Equipo, $e.Message) 'fail' }
        }
        $script:StatusText.Text = "Finalizado: $($summary.Ok) OK / $($summary.Failed) fallidos de $($summary.Total)."
    }
    elseif ($script:Sync.Error) {
        $script:StatusText.Text = "Termino con error: $($script:Sync.Error)"
    }
    else {
        $script:StatusText.Text = 'Finalizado.'
    }

    $script:Running = $false
    $script:BtnRun.IsEnabled = $true
    $script:BtnStop.IsEnabled = $false
    $script:Rail.IsEnabled = $true
    if ($script:DetailMode) { Update-DetailPanel }
}

function Stop-Deployment {
    if (-not $script:Running) { return }
    $script:Sync.Cancel['Cancel'] = $true
    $script:BtnStop.IsEnabled = $false
    $script:StatusText.Text = 'Cancelando: no se encolan mas equipos y se detienen los jobs en curso...'
    Add-ConsoleLine 'Cancelacion solicitada. Esperando a que se detengan los jobs en curso...' 'warn'
}

# ---------------------------------------------------------------------
# 8b. Detalle por equipo (click en OK / Fallidos)
#     Mismo comportamiento que Deploy-Web.ps1: OK muestra solo hostnames,
#     Fallidos muestra hostname + error. Se actualiza en vivo mientras el
#     panel esta abierto.
# ---------------------------------------------------------------------
function New-DetailItem {
    param([string]$Equipo, [string]$Mensaje, [switch]$Fail)

    $item = New-Object System.Windows.Controls.ListBoxItem

    if (-not $Fail) {
        # Ancho fijo: en el WrapPanel quedan como columnas parejas.
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $Equipo
        $tb.FontFamily = 'Consolas'
        $tb.FontSize = 12
        $tb.Width = 160
        $tb.TextTrimming = 'CharacterEllipsis'
        $tb.ToolTip = $Equipo
        $item.Content = $tb
        return $item
    }

    $grid = New-Object System.Windows.Controls.Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition
    $c0.Width = [System.Windows.GridLength]::Auto
    $c0.SharedSizeGroup = 'Host'      # alinea la columna con el encabezado
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    [void]$grid.ColumnDefinitions.Add($c0)
    [void]$grid.ColumnDefinitions.Add($c1)

    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $Equipo
    $h.FontFamily = 'Consolas'
    $h.FontSize = 12
    $h.FontWeight = 'SemiBold'
    $h.Margin = '0,0,14,0'
    [System.Windows.Controls.Grid]::SetColumn($h, 0)

    $m = New-Object System.Windows.Controls.TextBlock
    $m.Text = if ($Mensaje) { $Mensaje } else { '(sin detalle)' }
    $m.FontSize = 12
    $m.TextWrapping = 'Wrap'
    $m.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4A3566')
    [System.Windows.Controls.Grid]::SetColumn($m, 1)

    [void]$grid.Children.Add($h)
    [void]$grid.Children.Add($m)

    $row = New-Object System.Windows.Controls.Border
    $row.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#EEF0F3')
    $row.BorderThickness = '0,0,0,1'
    $row.Padding = '0,2,0,3'
    $row.Child = $grid
    $item.Content = $row
    return $item
}

# Pinta el estado abierto/cerrado de los dos botones (borde de color y
# chevron dado vuelta en el que esta abierto).
function Set-TileState {
    $conv = [System.Windows.Media.BrushConverter]::new()
    foreach ($t in @(
        @{ Tile = $script:TileOk;   Chev = $script:OkChevron;   Mode = 'ok';   Color = '#2E7D32' },
        @{ Tile = $script:TileFail; Chev = $script:FailChevron; Mode = 'fail'; Color = '#5B2A86' })) {

        if ($script:DetailMode -eq $t.Mode) {
            $t.Tile.Background      = [System.Windows.Media.Brushes]::White
            $t.Tile.BorderBrush     = $conv.ConvertFromString($t.Color)
            $t.Tile.BorderThickness = '2'
            $t.Tile.Padding         = '11,7'     # compensa el borde de 2 px
            $t.Chev.RenderTransform = [System.Windows.Media.ScaleTransform]::new(1, -1)
        }
        else {
            $t.Tile.Background      = $conv.ConvertFromString('#F5F6F8')
            $t.Tile.BorderBrush     = $conv.ConvertFromString('#E6E8EC')
            $t.Tile.BorderThickness = '1'
            $t.Tile.Padding         = '12,8'
            $t.Chev.RenderTransform = [System.Windows.Media.Transform]::Identity
        }
    }
}

# Contador, boton Copiar y mensaje de "vacio". Se llama tras cada cambio.
function Update-DetailCount {
    $n = $script:DetailList.Items.Count
    $isOk = ($script:DetailMode -eq 'ok')
    $script:DetailCount.Text = [string]$n
    $script:BtnCopyDetail.IsEnabled = ($n -gt 0)

    if ($n -gt 0) {
        $script:DetailEmpty.Visibility  = 'Collapsed'
        $script:DetailList.Visibility   = 'Visible'
        $script:DetailHeader.Visibility = if ($isOk) { 'Collapsed' } else { 'Visible' }
        return
    }

    $script:DetailList.Visibility   = 'Collapsed'
    $script:DetailHeader.Visibility = 'Collapsed'
    $script:DetailEmpty.Visibility  = 'Visible'
    $script:DetailEmpty.Text = if (-not $script:HasRun) { 'Todavia no se ejecuto ninguna tarea.' }
        elseif ($isOk)  { if ($script:Running) { 'Todavia ningun equipo termino OK.' } else { 'Ningun equipo termino OK.' } }
        else            { if ($script:Running) { 'Por ahora ningun equipo fallo.' } else { 'Ningun equipo fallo.' } }
}

# Redibuja el panel entero (al abrirlo, al cambiar de OK a Fallidos, al
# empezar una corrida y al terminar). En vivo solo se agregan filas.
function Update-DetailPanel {
    Set-TileState
    if (-not $script:DetailMode) {
        $script:DetailPanel.Visibility = 'Collapsed'
        return
    }

    $isOk = ($script:DetailMode -eq 'ok')
    $script:DetailPanel.Visibility = 'Visible'
    $script:DetailTitle.Text = if ($isOk) { 'EQUIPOS OK' } else { 'EQUIPOS FALLIDOS' }
    $script:DetailTitle.Foreground = $window.FindResource($(if ($isOk) { 'BrushOk' } else { 'BrushFail' }))
    $script:DetailList.ItemsPanel = $window.FindResource($(if ($isOk) { 'PanelGrid' } else { 'PanelList' }))
    $script:BtnCopyDetail.Content = 'Copiar hostnames'

    $script:DetailList.Items.Clear()
    if ($isOk) {
        foreach ($h in $script:OkList) { [void]$script:DetailList.Items.Add((New-DetailItem -Equipo $h)) }
    }
    else {
        foreach ($e in $script:FailList) {
            [void]$script:DetailList.Items.Add((New-DetailItem -Equipo $e.Equipo -Mensaje $e.Message -Fail))
        }
    }
    Update-DetailCount
}

# Click en OK / Fallidos: abre ese panel, o lo cierra si ya estaba abierto.
function Show-Detail {
    param([string]$Mode)
    $script:DetailMode = if ($script:DetailMode -eq $Mode) { $null } else { $Mode }
    Update-DetailPanel
}

# Solo hostnames, uno por linea: listo para pegar en un .txt de imports\ y
# reintentar los fallidos.
function Copy-DetailHostnames {
    $hosts = @(if ($script:DetailMode -eq 'ok') { $script:OkList.ToArray() }
               else { $script:FailList.ToArray() | ForEach-Object { $_.Equipo } })
    if ($hosts.Count -eq 0) { return }

    try {
        [System.Windows.Clipboard]::SetText(($hosts -join "`r`n"))
    }
    catch {
        $script:StatusText.Text = "No se pudo copiar al portapapeles: $($_.Exception.Message)"
        return
    }

    $script:BtnCopyDetail.Content = 'Copiado'
    $script:StatusText.Text = "$($hosts.Count) hostnames copiados al portapapeles."
    if (-not $script:CopyTimer) {
        $script:CopyTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:CopyTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
        $script:CopyTimer.Add_Tick({
            $script:BtnCopyDetail.Content = 'Copiar hostnames'
            $script:CopyTimer.Stop()
        })
    }
    $script:CopyTimer.Stop()
    $script:CopyTimer.Start()
}

# ---------------------------------------------------------------------
# 9. Eventos
# ---------------------------------------------------------------------
$script:BtnRun.Add_Click({ Start-Deployment })
$script:BtnStop.Add_Click({ Stop-Deployment })
$script:BtnReload.Add_Click({
    # Tambien se relee la config, por si se edito config\config.psd1 con la
    # ventana abierta (ahi vive la ruta de imports\).
    $script:Config = Get-DeploymentConfig -WarningAction SilentlyContinue
    Update-ImportCombo
    Update-ComputerPreview
})

$script:BtnOpenImports.Add_Click({
    $folder = $script:Config.ImportsPath
    if ($folder -and (Test-Path $folder)) {
        Start-Process explorer.exe $folder
    }
    else {
        [void][System.Windows.MessageBox]::Show(
            "No existe la carpeta $folder",
            'Imports', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    }
})
$script:BtnClear.Add_Click({ $script:LogList.Items.Clear() })
$script:TileOk.Add_Click({ Show-Detail -Mode 'ok' })
$script:TileFail.Add_Click({ Show-Detail -Mode 'fail' })
$script:BtnCloseDetail.Add_Click({ if ($script:DetailMode) { Show-Detail -Mode $script:DetailMode } })
$script:BtnCopyDetail.Add_Click({ Copy-DetailHostnames })
$script:ImportCombo.Add_SelectionChanged({ Update-ComputerPreview })
$script:PasteBox.Add_TextChanged({ if ($script:RbPaste.IsChecked) { Update-ComputerPreview } })

$script:RbFile.Add_Checked({
    $script:PasteBox.Visibility = 'Collapsed'
    $script:ImportCombo.IsEnabled = $true
    Update-ComputerPreview
})
$script:RbPaste.Add_Checked({
    $script:PasteBox.Visibility = 'Visible'
    $script:ImportCombo.IsEnabled = $false
    Update-ComputerPreview
})

$script:BtnOpenLog.Add_Click({
    if ($script:CurrentLog -and (Test-Path $script:CurrentLog)) {
        Start-Process notepad.exe $script:CurrentLog
    }
    else {
        [void][System.Windows.MessageBox]::Show(
            "Todavia no existe $($script:CurrentLog).",
            'Log', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
    }
})

$window.Add_Closing({
    if ($script:Running) {
        $r = [System.Windows.MessageBox]::Show(
            'Hay un despliegue en curso. Cancelarlo y cerrar?',
            'Despliegue en curso',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        if ($r -ne [System.Windows.MessageBoxResult]::Yes) {
            $_.Cancel = $true
            return
        }
        $script:Sync.Cancel['Cancel'] = $true
    }
    if ($script:Timer) { $script:Timer.Stop() }
})

# ---------------------------------------------------------------------
# 10. Atajos de teclado
# ---------------------------------------------------------------------
$window.Add_SizeChanged({ Update-ConsoleHeight })

# Al volver a la ventana (tipico: editaste el .txt en el Bloc de notas y
# volves) se relee la lista sola, sin tener que acordarse de "Recargar".
$window.Add_Activated({
    if ($script:CurrentTask -and -not $script:Running) { Update-ComputerPreview }
})

$window.Add_KeyDown({
    # F5 ejecuta, Escape cancela: comodo cuando se repite la misma tarea.
    if ($_.Key -eq 'F5' -and -not $script:Running) { Start-Deployment }
    elseif ($_.Key -eq 'Escape' -and $script:Running) { Stop-Deployment }
})

# ---------------------------------------------------------------------
# 11. Dimensionado adaptable
#
#     Nada de alto/ancho fijos: se toma el area de trabajo REAL del
#     monitor (ya descontada la barra de tareas, y en unidades
#     independientes de DPI, asi que contempla el escalado al 125/150%).
#     La ventana ocupa el 92% de esa area, con topes para que no quede
#     gigante en un monitor 4K, y nunca puede exceder la pantalla. En
#     pantallas chicas arranca maximizada directamente.
# ---------------------------------------------------------------------
$work = [System.Windows.SystemParameters]::WorkArea

$window.MaxWidth  = $work.Width
$window.MaxHeight = $work.Height

$targetWidth  = [Math]::Min(1180, $work.Width * 0.92)
$targetHeight = [Math]::Min(820, $work.Height * 0.92)

$window.Width  = [Math]::Max($window.MinWidth, $targetWidth)
$window.Height = [Math]::Max($window.MinHeight, $targetHeight)

if ($work.Width -lt 1100 -or $work.Height -lt 700) {
    $window.WindowState = 'Maximized'
}

# ---------------------------------------------------------------------
# 12. Arranque
# ---------------------------------------------------------------------
$script:HeaderRoot.Text = $script:Root
Update-ConsoleHeight
Build-Rail
Select-Task -TaskId $script:Tasks[0].Id
Add-ConsoleLine 'Deployment Toolkit - GUI lista. Elegi una tarea, revisa la lista de equipos y presiona Ejecutar (o F5).' 'muted'
Add-ConsoleLine "Repositorio: $($script:Config.RepositoryRoot)" 'muted'

[void]$window.ShowDialog()

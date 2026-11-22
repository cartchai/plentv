// Platform stub for warpbox.
//
// Adapted from sing-box's experimental/libbox config.go
// (platformInterfaceStub / interfaceMonitorStub, GPL-3.0-or-later): every
// platform call is a no-op because a proxy-only config never opens a
// TUN, never watches interfaces, never sends notifications. The box
// engine still wants a PlatformInterface in its context, so it gets
// this stub instead of a nil.

package warpbox

import (
	"context"
	"net/netip"
	"os"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/control"
	"github.com/sagernet/sing/common/logger"
	"github.com/sagernet/sing/common/x/list"
)

type platformStub struct{}

func (s *platformStub) Initialize(networkManager adapter.NetworkManager) error {
	return nil
}

func (s *platformStub) UsePlatformAutoDetectInterfaceControl() bool {
	return true
}

func (s *platformStub) AutoDetectInterfaceControl(fd int) error {
	return nil
}

func (s *platformStub) UsePlatformInterface() bool {
	return false
}

func (s *platformStub) OpenInterface(options *tun.Options, platformOptions option.TunPlatformOptions) (tun.Tun, error) {
	return nil, os.ErrInvalid
}

func (s *platformStub) ProcessPlatformOptions(options option.TunPlatformOptions) error {
	return nil
}

func (s *platformStub) UsePlatformDefaultInterfaceMonitor() bool {
	return true
}

func (s *platformStub) CreateDefaultInterfaceMonitor(logger logger.Logger) tun.DefaultInterfaceMonitor {
	return &interfaceMonitorStub{}
}

func (s *platformStub) UsePlatformNetworkInterfaces() bool {
	return false
}

func (s *platformStub) NetworkInterfaces() ([]adapter.NetworkInterface, error) {
	return nil, os.ErrInvalid
}

func (s *platformStub) UnderNetworkExtension() bool {
	return false
}

func (s *platformStub) NetworkExtensionIncludeAllNetworks() bool {
	return false
}

func (s *platformStub) ClearDNSCache() {
}

func (s *platformStub) RequestPermissionForWIFIState() error {
	return nil
}

func (s *platformStub) UsePlatformWIFIMonitor() bool {
	return false
}

func (s *platformStub) ReadWIFIState(ctx context.Context) adapter.WIFIState {
	return adapter.WIFIState{}
}

func (s *platformStub) UsePlatformConnectionOwnerFinder() bool {
	return false
}

func (s *platformStub) FindConnectionOwner(request *adapter.FindConnectionOwnerRequest) (*adapter.ConnectionOwner, error) {
	return nil, os.ErrInvalid
}

func (s *platformStub) UsePlatformNotification() bool {
	return false
}

func (s *platformStub) SendNotification(notification *adapter.Notification) error {
	return nil
}

func (s *platformStub) CancelNotification(identifier string, typeID int32) error {
	return nil
}

func (s *platformStub) MyInterfaceAddress() []netip.Addr {
	return nil
}

func (s *platformStub) UsePlatformNeighborResolver() bool {
	return false
}

func (s *platformStub) StartNeighborMonitor(listener adapter.NeighborUpdateListener) error {
	return os.ErrInvalid
}

func (s *platformStub) CloseNeighborMonitor(listener adapter.NeighborUpdateListener) error {
	return nil
}

func (s *platformStub) UsePlatformShell() bool {
	return false
}

func (s *platformStub) CheckPlatformShell() error {
	return nil
}

func (s *platformStub) OpenShellSession(user *adapter.PlatformUser, command string, env []string, term string, rows int32, cols int32) (adapter.ShellSession, error) {
	return nil, os.ErrInvalid
}

func (s *platformStub) LookupSFTPServer() (string, error) {
	return "", os.ErrInvalid
}

func (s *platformStub) ReadSystemSSHHostKey() ([]byte, error) {
	return nil, os.ErrInvalid
}

func (s *platformStub) TailscaleHostname() string {
	return ""
}

func (s *platformStub) UsePlatformBridge() bool {
	return false
}

func (s *platformStub) CreateBridge(options adapter.BridgeOptions) (adapter.BridgeSession, error) {
	return nil, os.ErrInvalid
}

func (s *platformStub) LookupUser(username string) (*adapter.PlatformUser, error) {
	return nil, os.ErrInvalid
}

type interfaceMonitorStub struct{}

func (s *interfaceMonitorStub) Start() error {
	return os.ErrInvalid
}

func (s *interfaceMonitorStub) Close() error {
	return os.ErrInvalid
}

func (s *interfaceMonitorStub) DefaultInterface() *control.Interface {
	return nil
}

func (s *interfaceMonitorStub) OverrideAndroidVPN() bool {
	return false
}

func (s *interfaceMonitorStub) AndroidVPNEnabled() bool {
	return false
}

func (s *interfaceMonitorStub) RegisterCallback(callback tun.DefaultInterfaceUpdateCallback) *list.Element[tun.DefaultInterfaceUpdateCallback] {
	return nil
}

func (s *interfaceMonitorStub) UnregisterCallback(element *list.Element[tun.DefaultInterfaceUpdateCallback]) {
}

func (s *interfaceMonitorStub) RegisterMyInterface(interfaceName string) {
}

func (s *interfaceMonitorStub) MyInterfaces() []string {
	return nil
}

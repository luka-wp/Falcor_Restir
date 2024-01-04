from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_Restir2():
    g = RenderGraph('Restir2')
    g.create_pass('RestirInitTemporal', 'RestirInitTemporal', {})
    g.create_pass('VBufferRT', 'VBufferRT', {'outputSize': 'Default', 'samplePattern': 'Center', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'useTraceRayInline': False, 'useDOF': True})
    g.add_edge('VBufferRT.vbuffer', 'RestirInitTemporal.vbuffer')
    g.add_edge('VBufferRT.mvec', 'RestirInitTemporal.motionVector')
    g.add_edge('VBufferRT.viewW', 'RestirInitTemporal.viewW')
    g.mark_output('RestirInitTemporal.outputColor')
    return g

Restir2 = render_graph_Restir2()
try: m.addGraph(Restir2)
except NameError: None

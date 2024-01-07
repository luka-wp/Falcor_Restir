from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_Restir3():
    g = RenderGraph('Restir3')
    g.create_pass('GBufferRT', 'GBufferRT', {'outputSize': 'Default', 'samplePattern': 'Center', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'texLOD': 'Mip0', 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('RestirInitTemporal', 'RestirInitTemporal', {})
    g.add_edge('GBufferRT.posW', 'RestirInitTemporal.posW')
    g.add_edge('GBufferRT.normW', 'RestirInitTemporal.normW')
    g.add_edge('GBufferRT.tangentW', 'RestirInitTemporal.tangentW')
    g.add_edge('GBufferRT.diffuseOpacity', 'RestirInitTemporal.diffuseOpacity')
    g.add_edge('GBufferRT.vbuffer', 'RestirInitTemporal.vbuffer')
    g.mark_output('RestirInitTemporal.outputColor')
    return g

Restir3 = render_graph_Restir3()
try: m.addGraph(Restir3)
except NameError: None

# Simple test for CAMB-iDEDM
# I have precomputed c_ells for \xi = -1 (extreme case)
# The test is to calculate the c_ells and compare
import os
import numpy as np
import camb

assert "CAMB-iDEDM" in os.path.dirname(camb.__file__), "Not using the correct CAMB version"

c_ells_expected = np.loadtxt("./docs/c_ells_total_xi=-1.txt")

pars = camb.CAMBparams()
pars.set_cosmology(thetastar=0.0104, ombh2=0.022, omch2=0.122, mnu=0.06, omk=0, tau=0.06)
pars.DarkEnergy.set_params(xi_interaction=-1, w=-0.999)
pars.set_matter_power(redshifts=[0], kmax=2.0)
results = camb.get_results(pars)

cmb_spectra = results.get_cmb_power_spectra(pars, CMB_unit='muK')
c_ells = cmb_spectra['total']

if not np.allclose(c_ells_expected, c_ells[:,0], atol=0, rtol=0.0001):
    print("Test failed!")
else:
    print("Test passed!")
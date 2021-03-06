/*
!=================================================================================================================================
! Copyright (c) 2016  Prof. Claus-Dieter Munz 
! This file is part of FLEXI, a high-order accurate framework for numerically solving PDEs with discontinuous Galerkin methods.
! For more information see https://www.flexi-project.org and https://nrg.iag.uni-stuttgart.de/
!
! FLEXI is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License 
! as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
!
! FLEXI is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
! of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License v3.0 for more details.
!
! You should have received a copy of the GNU General Public License along with FLEXI. If not, see <http://www.gnu.org/licenses/>.
!=================================================================================================================================
*/

#include "visu3DReader.h"
#include "../plugin_visu3D.h"

#include "hdf5.h"
#include <vtkCellArray.h>
#include <vtkCellData.h>
#include <vtkDoubleArray.h>
#include <vtkHexahedron.h>
#include <vtkQuad.h>
#include <vtkInformation.h>
#include <vtkInformationVector.h>
#include <vtkObjectFactory.h>
#include <vtkPointData.h>
#include <vtkStreamingDemandDrivenPipeline.h>
#include "vtkMultiBlockDataSet.h"
#include <vtkUnstructuredGrid.h>


#include <libgen.h>
#include <unistd.h>
#include <algorithm>
#include <sstream>

// MPI
#include "vtkMultiProcessController.h"
vtkStandardNewMacro(visu3DReader);
vtkCxxSetObjectMacro(visu3DReader, Controller, vtkMultiProcessController);

#define SWRITE(x) {if (ProcessId == 0) std::cout << "@@@ " << this << " " << x << "\n";};

/*
 * Construtor of State Reader
 */
visu3DReader::visu3DReader()
{
   SWRITE("visu3DReader");
   this->FileName = NULL;
   this->NVisu = 0;
   this->NodeTypeVisu = NULL;
   this->Mode2d = 0;
   this->DGonly = 0;
   this->ParameterFileOverwrite = NULL;
   this->MeshFileOverwrite = NULL;
   this->SetNumberOfInputPorts(0);

   // Setup the selection callback to modify this object when an array
   // selection is changed.
   // Used to tell the visu3DReader, that we (un)selected a state,primite or derived quantity
   // and that the 'Apply' button becomes clickable to reload the data (load the selected quantities)

   this->SelectionObserver = vtkCallbackCommand::New();
   this->SelectionObserver->SetCallback(&visu3DReader::SelectionModifiedCallback);
   this->SelectionObserver->SetClientData(this);
   // create array for state,primitive and derived quantities
   this->VarDataArraySelection = vtkDataArraySelection::New();
   // add an observer 
   this->VarDataArraySelection->AddObserver(vtkCommand::ModifiedEvent, this->SelectionObserver);

}

/*
 * This function is called when a file is inserted into the Pipeline-browser.
 * Here we load the variable names (state,primitive, derived).
 */
int visu3DReader::RequestInformation(vtkInformation *,
      vtkInformationVector **,
      vtkInformationVector *outputVector)
{
   // We take the first state file and use it to read the varnames
   SWRITE("RequestInformation: State file: " << FileNames[0]);

   // Set up MPI communicator   
   this->Controller = NULL;
   this->SetController(vtkMultiProcessController::GetGlobalController());
   if (this->Controller == NULL) {
      NumProcesses = 1;
      ProcessId = 0;
   } else {
      NumProcesses = this->Controller->GetNumberOfProcesses();
      ProcessId = this->Controller->GetLocalProcessId();
   }

   vtkMPICommunicator *communicator = vtkMPICommunicator::SafeDownCast(this->Controller->GetCommunicator());
   mpiComm = MPI_COMM_NULL;
   if (communicator) {
      mpiComm = *(communicator->GetMPIComm()->GetHandle());
   }

   // get the info object of the output ports 
   vtkSmartPointer<vtkInformation> outInfo = outputVector->GetInformationObject(0);

   // sets the number of pieces to the number of processsors
   outInfo->Set(CAN_HANDLE_PIECE_REQUEST(), 1);

   // if we have more then one file loaded at once (timeseries)
   // we have to set the number and range of the timesteps
   double timeRange[2] = {Timesteps[0], Timesteps[Timesteps.size()-1]};
   outInfo->Set(vtkStreamingDemandDrivenPipeline::TIME_STEPS(), &Timesteps[0], Timesteps.size());
   outInfo->Set(vtkStreamingDemandDrivenPipeline::TIME_RANGE(), timeRange, 2);

   // Change to directory of state file (path of mesh file is stored relative to path of state file)
   char* dir = strdup(FileNames[0].c_str());
   dir = dirname(dir);
   int ret = chdir(dir);
   if (ret != 0) {
      SWRITE("Directory of state file not found: " << dir);
      return 0;
   }
   
   // convert the MPI communicator to a Fortran communicator
   int fcomm;
   fcomm = MPI_Comm_c2f(mpiComm);
   MPI_Barrier(mpiComm);

   struct CharARRAY varnames;
   // Call Posti-function requestInformation:
   // This function returns the varnames of state, primitive and derived quantities
   int str_len = strlen(FileNames[0].c_str());
   __mod_visu3d_MOD_visu3d_requestinformation(&fcomm, &str_len, FileNames[0].c_str(), &varnames);

   MPI_Barrier(mpiComm);

   // We copy the varnames to the corresponding DataArraySelection objects.
   // These objects are used to build the gui. 
   // (see the functions below: 
   //   DisableAllVarArrays, EnableAllVarArrays, GetNumberOfVarArrays, GetVarArrayName, GetVarArrayStatus, SetVarArrayStatus,
   // )
   for (int iVar=0; iVar<varnames.len/255; iVar++) {
      char tmps[255];
      strncpy(tmps, varnames.data+iVar*255, 255);
      std::string varname(tmps);
      varname = varname.substr(0,varname.find(" "));

      if (!this->VarDataArraySelection->ArrayExists(varname.c_str())) {
         // function DisableArray deselects the varname in the gui and if not existend inserts the varname         
         this->VarDataArraySelection->DisableArray(varname.c_str());


         // Select Density, FV_Elems by default
         if (varname.compare("Density") == 0) this->VarDataArraySelection->EnableArray(varname.c_str());
         if (varname.compare("ElemData:FV_Elems") == 0) this->VarDataArraySelection->EnableArray(varname.c_str());
      }
   }
   return 1; 
}

/*
 * This function is called whenever a filename is loaded.
 * If multiple files are selected in the file-dialog, this function is called multiple times.
 * Attention: For multiple files, we assume a timeseries.
 */
void visu3DReader::AddFileName(const char* filename_in) {
   SWRITE("AddFileName");
   // append the filename to the list of filenames
   this->FileNames.push_back(filename_in);
   this->Modified();

   // open the file with HDF5 and read the attribute 'time' to build a timeseries  
   hid_t state = H5Fopen(filename_in, H5F_ACC_RDONLY, H5P_DEFAULT);
   hid_t attr = H5Aopen(state, "Time", H5P_DEFAULT);
   SWRITE("attribute Time"<<attr);
   double time; 
   if (attr > -1){
      hid_t attr_type = H5Aget_type( attr );
      H5Aread(attr, attr_type, &time);
      Timesteps.push_back(time);
   }else{
      Timesteps.push_back(0.);
   }
   H5Aclose(attr);
   H5Fclose(state);
}

void visu3DReader::RemoveAllFileNames() {
   this->FileNames.clear();
   this->Timesteps.clear();
}

// Get number of state file in the filenames list closest to the requested time
int visu3DReader::FindClosestTimeStep(double requestedTimeValue)
{
   int ts = 0;
   double mindist = fabs(Timesteps[0] - requestedTimeValue);

   for (unsigned int i = 0; i < Timesteps.size(); i++) {
      double tsv = Timesteps[i];
      double dist = fabs(tsv - requestedTimeValue);
      if (dist < mindist) {
         mindist = dist;
         ts = i;
      }
   }
   return ts;
}

vtkStringArray* visu3DReader::GetNodeTypeVisuList() {
   vtkStringArray* arr = vtkStringArray::New();
   arr->InsertNextValue("VISU");
   arr->InsertNextValue("GAUSS");
   arr->InsertNextValue("GAUSS-LOBATTO");
   arr->InsertNextValue("VISU_INNER");
   return arr;
}

/*
 * This function is called, when the user presses the 'Apply' button.
 * Here we call the Posti and load all the data.
 */
   
int visu3DReader::RequestData(
      vtkInformation *vtkNotUsed(request),
      vtkInformationVector **vtkNotUsed(inputVector),
      vtkInformationVector *outputVector)
{
   SWRITE("RequestData");

   // get the index of the timestep to load
   int timestepToLoad = 0;
   std::string FileToLoad;
   vtkSmartPointer<vtkInformation> outInfo = outputVector->GetInformationObject(0);
   if (outInfo->Has(vtkStreamingDemandDrivenPipeline::UPDATE_TIME_STEP())) {
      // get the requested time
      double requestedTimeValue = outInfo->Get(vtkStreamingDemandDrivenPipeline::UPDATE_TIME_STEP());
      timestepToLoad = FindClosestTimeStep(requestedTimeValue);
      FileToLoad = FileNames[timestepToLoad];
   }


   // convert the MPI communicator to a fortran communicator
   int fcomm = MPI_Comm_c2f(mpiComm);
   MPI_Barrier(mpiComm); // all processes should call the Fortran code at the same time

   // get all variables selected for visualization 
   // and check if they are the same as before (bug workaround, explanation see below)
   int nVars = VarDataArraySelection->GetNumberOfArrays();
   VarNames_selected.resize(nVars);
   for (int i = 0; i< nVars; ++i)
   {
      const char* name = VarDataArraySelection->GetArrayName(i);
      VarNames_selected[i] = VarDataArraySelection->ArrayIsEnabled(name);
   }

   // Change to directory of state file (path of mesh file is stored relative to path of state file)
   char* dir = strdup(FileToLoad.c_str());
   dir = dirname(dir);
   int ret = chdir(dir);
   if (ret != 0) {
      SWRITE("Directory of state file not found: " << dir);
      return 0;
   }

   // Write temporary parameter file for Posti tool 
   // TODO: only root-proc
   //if (ProcessId == 0) {

   // get temporary file for the posti parameter files
   setlocale(LC_ALL, "C"); 
   char posti_filename[] = "/tmp/f2p_posti_XXXXXX.ini";
   int posti_unit = mkstemps(posti_filename,4);

   // write settings to Posti parameter file
   dprintf(posti_unit, "NVisu = %d\n", NVisu); // insert NVisu
   dprintf(posti_unit, "NodeTypeVisu = %s\n", NodeTypeVisu); // insert NodeType
   dprintf(posti_unit, "VisuDimension = %s\n", (this->Mode2d ? "2" : "3"));
   dprintf(posti_unit, "DGonly = %s\n", (this->DGonly ? "T" : "F"));
   if (strlen(MeshFileOverwrite) > 0) {
      dprintf(posti_unit, "MeshFile = %s\n", MeshFileOverwrite);
   }

   // write selected state varnames to the parameter file
   for (int i = 0; i< nVars; ++i)
   {
      if (VarNames_selected[i]) {
         const char* name = VarDataArraySelection->GetArrayName(i);
         dprintf(posti_unit, "VarName = %s\n", name) ;
      }
   }
   close(posti_unit);

   MPI_Barrier(mpiComm); // all processes should call the Fortran code at the same time

   // call Posti tool (Fortran code)
   // the arrays coords_*, values_* and nodeids_* are allocated in the Posti tool 
   // and contain the vtk data
   int strlen_prm = strlen(ParameterFileOverwrite);
   int strlen_posti = strlen(posti_filename);
   int strlen_state = strlen(FileToLoad.c_str()); 
   __mod_visu3d_MOD_visu3d_cwrapper(&fcomm, 
         &strlen_prm, ParameterFileOverwrite, 
         &strlen_posti, posti_filename, 
         &strlen_state, FileToLoad.c_str(),
         &coords_DG,&values_DG,&nodeids_DG,
         &coords_FV,&values_FV,&nodeids_FV,&varnames,&components);

   MPI_Barrier(mpiComm); // wait until all processors returned from the Fortran Posti code


   // get the MultiBlockDataset 
   vtkMultiBlockDataSet* mb = vtkMultiBlockDataSet::SafeDownCast(outInfo->Get(vtkDataObject::DATA_OBJECT()));
   if (!mb) {
      std::cout << "DownCast to MultiBlockDataset Failed!" << std::endl;
      return 0;
   }

   // adjust the number of Blocks in the MultiBlockDataset to 2 (DG and FV)
   SWRITE("Number of Blocks in MultiBlockDataset : " << mb->GetNumberOfBlocks());
   if (mb->GetNumberOfBlocks() < 2) {
      SWRITE("Create new DG and FV output Blocks");
      mb->SetBlock(0, vtkUnstructuredGrid::New());
      mb->SetBlock(1, vtkUnstructuredGrid::New());
   }

    // Insert DG data into output
   vtkSmartPointer<vtkUnstructuredGrid> output_DG = vtkUnstructuredGrid::SafeDownCast(mb->GetBlock(0));
   InsertData(output_DG, &coords_DG, &values_DG, &nodeids_DG, &varnames, &components);

    // Insert FV data into output
   vtkSmartPointer<vtkUnstructuredGrid> output_FV = vtkUnstructuredGrid::SafeDownCast(mb->GetBlock(1));
   InsertData(output_FV, &coords_FV, &values_FV, &nodeids_FV, &varnames, &components);

   __mod_visu3d_MOD_visu3d_dealloc_nodeids();

   // tell paraview to render data
   this -> Modified(); 

   MPI_Barrier(mpiComm); // synchronize again (needed?)
   SWRITE("RequestData finished");
   return 1;
}


/*
 * This function inserts the data, loaded by the Posti tool, into a ouput
 */
void visu3DReader::InsertData(vtkSmartPointer<vtkUnstructuredGrid> &output, struct DoubleARRAY* coords,
      struct DoubleARRAY* values, struct IntARRAY* nodeids, struct CharARRAY* varnames, struct IntARRAY* components) {
   // create a 3D double array (must be 3D even we use a 2D Posti tool, since paraview holds the data in 3D)
   vtkSmartPointer <vtkDoubleArray> pdata = vtkSmartPointer<vtkDoubleArray>::New();
   pdata->SetNumberOfComponents(3); // 3D
   pdata->SetNumberOfTuples(coords->len/3);
   // copy coordinates 
   double* ptr = pdata->GetPointer(0);
   for (long i = 0; i < coords->len; ++i)
   {
      *ptr++ = coords->data[i];
   }

   // create points array to be used for the output
   vtkSmartPointer<vtkPoints> points = vtkSmartPointer<vtkPoints>::New();
   points->SetData(pdata);
   output->SetPoints(points);

   // create cellarray
   vtkSmartPointer<vtkCellArray> cellarray = vtkSmartPointer<vtkCellArray>::New();
   if (this->Mode2d) {
      vtkSmartPointer<vtkQuad> quad = vtkSmartPointer<vtkQuad>::New();
      // Use the nodeids to build quads
      // (here we must copy the nodeids, we can not just assign the array of nodeids to some vtk-structure)
      int gi = 0;
      // loop over all Quads
      for (int iQuad=0; iQuad<nodeids->len/4; iQuad++) {
         // each Quad has 4 points
         for (int i=0; i<4; i++) {
            quad->GetPointIds()->SetId(i, nodeids->data[gi]);
            gi++;
         }
         // insert the quad into the cellarray
         cellarray->InsertNextCell(quad);
      }
      output->SetCells({VTK_QUAD}, cellarray);
   } else {
      vtkSmartPointer<vtkHexahedron> hex = vtkSmartPointer<vtkHexahedron>::New();
      // Use the nodeids to build hexas
      // (here we must copy the nodeids, we can not just assign the array of nodeids to some vtk-structure)
      int gi = 0;
      // loop over all Hexas
      for (int iHex=0; iHex<nodeids->len/8; iHex++) {
         // each Hex has 8 points
         for (int i=0; i<8; i++) {
            hex->GetPointIds()->SetId(i, nodeids->data[gi]);
            gi++;
         }
         // insert the hex into the cellarray
         cellarray->InsertNextCell(hex);
      }
      output->SetCells({VTK_HEXAHEDRON}, cellarray);
   }

   // assign the actual data, loaded by the Posti tool, to the output
   unsigned int nVarCombine = varnames->len/255;
   if (nVarCombine > 0) {
      unsigned int nVar = 0;
      for (unsigned int iVar=0;iVar<nVarCombine;iVar++) {
         nVar += components->data[iVar];
      }
      unsigned int sizePerVar = values->len/nVar;
      int dataPos = 0;
      // loop over all loaded variables
      for (unsigned int iVar = 0; iVar < nVarCombine; iVar++) {
         // For each variable, create a new array and set the number of components to 1
         // Each variable is loaded separately. 
         // One might implement vector variables (velocity), but then must set number of componenets to 2/3
         vtkSmartPointer <vtkDoubleArray> vdata = vtkSmartPointer<vtkDoubleArray>::New();
         vdata->SetNumberOfComponents(components->data[iVar]);
         vdata->SetNumberOfTuples(sizePerVar/components->data[iVar]);
         // copy coordinates 
         double* ptr = vdata->GetPointer(0);
         for (long i = 0; i < sizePerVar; ++i)
         {
            *ptr++ = values->data[dataPos+i];
         }
         dataPos += sizePerVar * components->data[iVar];
         // set name of variable
         char tmps[255];
         strncpy(tmps, varnames->data+iVar*255, 255);
         std::string varname(tmps);
         varname = varname.substr(0,varname.find(" "));
         vdata->SetName(varname.c_str());
         // insert array of variable into the output
         output->GetPointData()->AddArray(vdata);
      }
   }
}

visu3DReader::~visu3DReader(){
   SWRITE("~visu3DReader");
   delete [] FileName;
   this->VarDataArraySelection->Delete();
}

/*
 * The following functions create the interaction between this Reader and 
 * the gui, which is defined in the visu2DReader.xml
 * They return the number of available variables (state,primitive, derived)
 * and return the names of the variables, ....
 */

void visu3DReader::DisableAllVarArrays()
{
   this->VarDataArraySelection->DisableAllArrays();
}
void visu3DReader::EnableAllVarArrays()
{
   this->VarDataArraySelection->EnableAllArrays();
}
int visu3DReader::GetNumberOfVarArrays()
{
   return this->VarDataArraySelection->GetNumberOfArrays();
}

const char* visu3DReader::GetVarArrayName(int index)
{
   if (index >= ( int ) this->GetNumberOfVarArrays() || index < 0)
   {
      return NULL;
   }
   else
   {
      return this->VarDataArraySelection->GetArrayName(index);
   }
}
int visu3DReader::GetVarArrayStatus(const char* name)
{
   return this->VarDataArraySelection->ArrayIsEnabled(name);
}

void visu3DReader::SetVarArrayStatus(const char* name, int status)
{
   if (status)
   {
      this->VarDataArraySelection->EnableArray(name);
   }
   else
   {
      this->VarDataArraySelection->DisableArray(name);
   }
}

void visu3DReader::SelectionModifiedCallback(vtkObject*, unsigned long,
      void* clientdata, void*)
{
   static_cast<visu3DReader*>(clientdata)->Modified();
}

int visu3DReader::FillOutputPortInformation(
      int vtkNotUsed(port), vtkInformation* info)
{
   info->Set(vtkDataObject::DATA_TYPE_NAME(), "vtkMultiBlockDataSet");
   return 1;
}


